(** Unit tests for [Attachment_store]: magic-byte sniffing, active-content and
    MIME-spoofing rejection, dimension parsing, deduplication, integrity checks,
    ephemeral LRU pruning & durable promotion, reachability ID extraction, and
    image derivatives. *)

module A = Attachment_store

let with_temp_base_path f =
  let dir = Filename.temp_file "masc_attachment_store_test_" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let cleanup () =
    let rec rm path =
      if Sys.file_exists path
      then
        if Sys.is_directory path
        then (
          Array.iter (fun n -> rm (Filename.concat path n)) (Sys.readdir path);
          Unix.rmdir path)
        else Unix.unlink path
    in
    try rm dir with
    | Sys_error _ | Unix.Unix_error _ -> ()
  in
  let r =
    try Ok (f dir) with
    | e -> Error e
  in
  cleanup ();
  match r with
  | Ok v -> v
  | Error e -> raise e
;;

let make_png ~width ~height ~seed =
  let rgb =
    String.init (width * height * 3) (fun i -> Char.chr ((i + seed) land 0xff))
  in
  match Rgb_png.encode ~width ~height ~rgb with
  | Ok png -> png
  | Error msg -> Alcotest.fail ("Rgb_png.encode failed: " ^ msg)
;;

(* Minimal valid JPEG header carrying SOF0 (width=16, height=12) + EOI. *)
let minimal_jpeg_header ~width ~height =
  let buf = Buffer.create 32 in
  Buffer.add_string buf "\xff\xd8";
  (* SOF0 marker: length=11, precision=8, height(2), width(2), components=1, comp spec(3) *)
  Buffer.add_string buf "\xff\xc0\x00\x0b\x08";
  Buffer.add_char buf (Char.chr ((height lsr 8) land 0xff));
  Buffer.add_char buf (Char.chr (height land 0xff));
  Buffer.add_char buf (Char.chr ((width lsr 8) land 0xff));
  Buffer.add_char buf (Char.chr (width land 0xff));
  Buffer.add_string buf "\x01\x01\x11\x00";
  Buffer.add_string buf "\xff\xd9";
  Buffer.contents buf
;;

(* Minimal GIF89a header with logical screen width x height. *)
let minimal_gif ~width ~height =
  let buf = Buffer.create 16 in
  Buffer.add_string buf "GIF89a";
  Buffer.add_char buf (Char.chr (width land 0xff));
  Buffer.add_char buf (Char.chr ((width lsr 8) land 0xff));
  Buffer.add_char buf (Char.chr (height land 0xff));
  Buffer.add_char buf (Char.chr ((height lsr 8) land 0xff));
  Buffer.add_string buf "\x00\x00\x00\x3b";
  Buffer.contents buf
;;

(* Minimal WebP VP8X container with canvas width x height. *)
let minimal_webp_vp8x ~width ~height =
  let w_m1 = width - 1 in
  let h_m1 = height - 1 in
  let buf = Buffer.create 32 in
  Buffer.add_string buf "RIFF\x16\x00\x00\x00WEBP";
  Buffer.add_string buf "VP8X\x0a\x00\x00\x00\x00\x00\x00\x00";
  Buffer.add_char buf (Char.chr (w_m1 land 0xff));
  Buffer.add_char buf (Char.chr ((w_m1 lsr 8) land 0xff));
  Buffer.add_char buf (Char.chr ((w_m1 lsr 16) land 0xff));
  Buffer.add_char buf (Char.chr (h_m1 land 0xff));
  Buffer.add_char buf (Char.chr ((h_m1 lsr 8) land 0xff));
  Buffer.add_char buf (Char.chr ((h_m1 lsr 16) land 0xff));
  Buffer.contents buf
;;

let minimal_pdf = "%PDF-1.7\n1 0 obj\n<<>>\nendobj\n%%EOF\n"
let minimal_wav = "RIFF\x24\x00\x00\x00WAVEfmt \x10\x00\x00\x00"
let minimal_ogg = "OggS\x00\x02\x00\x00\x00\x00"
let minimal_midi = "MThd\x00\x00\x00\x06\x00\x01\x00\x01\x00\x60"
let minimal_mp3_id3 = "ID3\x03\x00\x00\x00\x00\x00\x00frame"
let minimal_mp3_sync = "\xff\xfb\x90\x00audio-frame"
let utf16le_bom_spaces = "\xff\xfe \x00h\x00i\x00"
let minimal_m4a = "\x00\x00\x00\x18ftypM4A \x00\x00\x00\x00M4A isom"
let minimal_mp4_isom_audio = "\x00\x00\x00\x14ftypisom\x00\x00\x02\x00isom\x00\x00\x00\x18hdlr\x00\x00\x00\x00\x00\x00\x00\x00soun"
let minimal_m4v_video = "\x00\x00\x00\x18ftypM4V \x00\x00\x00\x00M4V isom"
let minimal_mp4_isom_with_vide = "\x00\x00\x00\x14ftypisom\x00\x00\x02\x00isom\x00\x00\x00\x18hdlr\x00\x00\x00\x00\x00\x00\x00\x00vide"
let minimal_qt_mov = "\x00\x00\x00\x14ftypqt  \x00\x00\x00\x00qt  "
let minimal_audio_webm = "\x1a\x45\xdf\xa3\x9f\x42\x86\x81\x01\x42\x82\x84webm\x83\x81\x02A_OPUS"
let minimal_video_webm_vp9 = "\x1a\x45\xdf\xa3\x9f\x42\x86\x81\x01\x42\x82\x84webmV_VP9"
let minimal_video_webm_track = "\x1a\x45\xdf\xa3\x9f\x42\x86\x81\x01\x42\x82\x84webm\x83\x81\x01"
let minimal_flac = "fLaC\x00\x00\x00\x22opaque-flac-payload"

(* Complete valid 1x1 GIF89a image decodable by sips/magick. *)
let valid_1x1_gif =
  "GIF89a\x01\x00\x01\x00\x80\x00\x00\xff\xff\xff\x00\x00\x00\x21\xf9\x04\x01\x00\x00\x00\x00\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00\x3b"
;;

let test_magic_sniffing_and_dimensions () =
  let png = make_png ~width:13 ~height:7 ~seed:1 in
  let jpg = minimal_jpeg_header ~width:320 ~height:240 in
  let gif = minimal_gif ~width:64 ~height:48 in
  let webp = minimal_webp_vp8x ~width:800 ~height:600 in
  Alcotest.(check (option string))
    "sniff png"
    (Some "image/png")
    (Option.map A.mime_to_string (A.sniff_mime png));
  Alcotest.(check (option string))
    "sniff jpeg"
    (Some "image/jpeg")
    (Option.map A.mime_to_string (A.sniff_mime jpg));
  Alcotest.(check (option string))
    "sniff gif"
    (Some "image/gif")
    (Option.map A.mime_to_string (A.sniff_mime gif));
  Alcotest.(check (option string))
    "sniff webp"
    (Some "image/webp")
    (Option.map A.mime_to_string (A.sniff_mime webp));
  Alcotest.(check (option string))
    "sniff pdf"
    (Some "application/pdf")
    (Option.map A.mime_to_string (A.sniff_mime minimal_pdf));
  Alcotest.(check (option string))
    "sniff wav"
    (Some "audio/wav")
    (Option.map A.mime_to_string (A.sniff_mime minimal_wav));
  Alcotest.(check (option string))
    "sniff ogg"
    (Some "audio/ogg")
    (Option.map A.mime_to_string (A.sniff_mime minimal_ogg));
  Alcotest.(check (option string))
    "sniff midi"
    (Some "audio/midi")
    (Option.map A.mime_to_string (A.sniff_mime minimal_midi));
  Alcotest.(check (option string))
    "sniff mp3 id3"
    (Some "audio/mpeg")
    (Option.map A.mime_to_string (A.sniff_mime minimal_mp3_id3));
  Alcotest.(check (option string))
    "sniff mp3 sync"
    (Some "audio/mpeg")
    (Option.map A.mime_to_string (A.sniff_mime minimal_mp3_sync));
  Alcotest.(check (option string))
    "sniff m4a audio/mp4"
    (Some "audio/mp4")
    (Option.map A.mime_to_string (A.sniff_mime minimal_m4a));
  Alcotest.(check (option string))
    "sniff isom audio-only mp4"
    (Some "audio/mp4")
    (Option.map A.mime_to_string (A.sniff_mime minimal_mp4_isom_audio));
  Alcotest.(check (option string))
    "sniff M4V as video/mp4"
    (Some "video/mp4")
    (Option.map A.mime_to_string (A.sniff_mime minimal_m4v_video));
  Alcotest.(check (option string))
    "sniff isom MP4 containing vide hdlr track as video/mp4"
    (Some "video/mp4")
    (Option.map A.mime_to_string (A.sniff_mime minimal_mp4_isom_with_vide));
  Alcotest.(check (option string))
    "sniff QuickTime qt as video/quicktime"
    (Some "video/quicktime")
    (Option.map A.mime_to_string (A.sniff_mime minimal_qt_mov));
  Alcotest.(check (option string))
    "sniff audio/webm"
    (Some "audio/webm")
    (Option.map A.mime_to_string (A.sniff_mime minimal_audio_webm));
  Alcotest.(check (option string))
    "sniff video/webm V_VP9"
    (Some "video/webm")
    (Option.map A.mime_to_string (A.sniff_mime minimal_video_webm_vp9));
  Alcotest.(check (option string))
    "sniff video/webm TrackType video"
    (Some "video/webm")
    (Option.map A.mime_to_string (A.sniff_mime minimal_video_webm_track));
  Alcotest.(check (option string))
    "reject unknown bytes"
    None
    (Option.map A.mime_to_string (A.sniff_mime "plain text hello"));
  Alcotest.(check (option string))
    "reject utf-16le bom as audio/mpeg"
    None
    (Option.map A.mime_to_string (A.sniff_mime utf16le_bom_spaces));
  (* UTF-8 codepoint boundary truncation in sanitize_filename *)
  let long_korean = "a" ^ String.concat "" (List.init 70 (fun _ -> "가")) in
  (match A.sanitize_filename long_korean with
   | None -> Alcotest.fail "expected sanitized UTF-8 filename"
   | Some s ->
     Alcotest.(check bool) "truncated <= 180 bytes" true (String.length s <= 180);
     Alcotest.(check int) "1 ASCII + 59 * 3-byte Korean = 178 bytes" 178 (String.length s);
     Alcotest.(check bool) "truncated filename is valid UTF-8" true (String.is_valid_utf_8 s));
  Alcotest.(check (option (pair int int)))
    "png dims"
    (Some (13, 7))
    (A.detect_image_dimensions png);
  Alcotest.(check (option (pair int int)))
    "jpeg dims"
    (Some (320, 240))
    (A.detect_image_dimensions jpg);
  Alcotest.(check (option (pair int int)))
    "gif dims"
    (Some (64, 48))
    (A.detect_image_dimensions gif);
  Alcotest.(check (option (pair int int)))
    "webp dims"
    (Some (800, 600))
    (A.detect_image_dimensions webp);
  Alcotest.(check (option (pair int int)))
    "pdf has no dims"
    None
    (A.detect_image_dimensions minimal_pdf)
;;

let test_security_rejections () =
  with_temp_base_path (fun base_path ->
    let store = A.create ~base_path in
    let put ?max_bytes ?declared_mime bytes =
      A.put
        ?max_bytes
        ?declared_mime
        ~origin:A.User_upload
        ~created_by:"alice"
        ~retention:A.Durable
        store
        ~bytes
    in
    (match put "" with
     | Error A.Empty_payload -> ()
     | Ok _ | Error _ -> Alcotest.fail "expected Empty_payload");
    let png = make_png ~width:4 ~height:4 ~seed:2 in
    (match put ~max_bytes:10 png with
     | Error (A.Payload_too_large { maximum = 10; _ }) -> ()
     | Ok _ | Error _ -> Alcotest.fail "expected Payload_too_large");
    (match put ~declared_mime:"image/svg+xml" "<svg xmlns='http://www.w3.org/2000/svg'/>" with
     | Error (A.Forbidden_mime "image/svg+xml") -> ()
     | Ok _ | Error _ -> Alcotest.fail "expected Forbidden_mime for declared SVG");
    (match put "<svg onload='alert(1)'></svg>" with
     | Error (A.Forbidden_mime "image/svg+xml") -> ()
     | Ok _ | Error _ -> Alcotest.fail "expected Forbidden_mime for sniffed SVG");
    (match put "<?xml version=\"1.0\"?><svg></svg>" with
     | Error (A.Forbidden_mime "image/svg+xml") -> ()
     | Ok _ | Error _ -> Alcotest.fail "expected Forbidden_mime for XML SVG");
    (match put ~declared_mime:"text/html" "<!DOCTYPE html><html></html>" with
     | Error (A.Forbidden_mime "text/html") -> ()
     | Ok _ | Error _ -> Alcotest.fail "expected Forbidden_mime for HTML");
    (match put "<html><script>alert(1)</script></html>" with
     | Error (A.Forbidden_mime "text/html") -> ()
     | Ok _ | Error _ -> Alcotest.fail "expected Forbidden_mime for sniffed HTML");
    (* Spoofing: PNG bytes declared as image/jpeg must be rejected. *)
    (match put ~declared_mime:"image/jpeg" png with
     | Error (A.Mime_mismatch { declared = "image/jpeg"; sniffed = "image/png" }) -> ()
     | Ok _ | Error _ -> Alcotest.fail "expected Mime_mismatch on spoofed PNG->JPEG");
    (* Unknown binary bytes must be rejected even with image/png header. *)
    (match put ~declared_mime:"image/png" "not actually a png" with
     | Error (A.Unsupported_or_unknown_format _) -> ()
     | Ok _ | Error _ -> Alcotest.fail "expected Unsupported_or_unknown_format");
    (* Nothing was written to blobs/ *)
    match A.list_all_blobs store with
    | Ok blobs -> Alcotest.(check (list string)) "no blobs stored on rejection" [] blobs
    | Error err -> Alcotest.fail err)
;;

let test_put_dedup_wire_json_and_integrity () =
  with_temp_base_path (fun base_path ->
    let store = A.create ~base_path in
    let png = make_png ~width:16 ~height:9 ~seed:7 in
    let meta1 =
      match
        A.put
          ~now:1700000000.0
          ~declared_mime:"image/png"
          ~filename:"../../evil/shot;\"1.png"
          ~origin:A.User_upload
          ~created_by:"vincent"
          ~retention:A.Durable
          store
          ~bytes:png
      with
      | Ok m -> m
      | Error err -> Alcotest.fail (A.put_error_to_string err)
    in
    Alcotest.(check bool)
      "canonical id prefix"
      true
      (String.starts_with ~prefix:"att_" meta1.id);
    Alcotest.(check string) "mime" "image/png" meta1.mime_type;
    Alcotest.(check int) "bytes" (String.length png) meta1.bytes;
    Alcotest.(check (option int)) "width" (Some 16) meta1.width;
    Alcotest.(check (option int)) "height" (Some 9) meta1.height;
    Alcotest.(check (option string)) "sanitized filename" (Some "shot1.png") meta1.filename;
    (* Wire JSON must match frozen contract keys *)
    let wire = A.meta_to_wire_json meta1 in
    let open Yojson.Safe.Util in
    Alcotest.(check string) "wire id" meta1.id (wire |> member "id" |> to_string);
    Alcotest.(check string)
      "wire attachment_id"
      meta1.id
      (wire |> member "attachment_id" |> to_string);
    Alcotest.(check string) "wire sha256" meta1.sha256 (wire |> member "sha256" |> to_string);
    Alcotest.(check string)
      "wire url"
      ("/api/v1/attachments/" ^ meta1.id)
      (wire |> member "url" |> to_string);
    Alcotest.(check string) "wire kind" "image" (wire |> member "kind" |> to_string);
    Alcotest.(check string) "wire origin" "user_upload" (wire |> member "origin" |> to_string);
    Alcotest.(check string) "wire retention" "durable" (wire |> member "retention" |> to_string);
    (* Dedup: re-uploading same bytes returns same ID and keeps 1 blob *)
    let meta2 =
      match
        A.put
          ~now:1700000050.0
          ~origin:A.Model_generated
          ~created_by:"keeper"
          ~retention:(A.Ephemeral { keeper = "alpha" })
          store
          ~bytes:png
      with
      | Ok m -> m
      | Error err -> Alcotest.fail (A.put_error_to_string err)
    in
    Alcotest.(check string) "dedup id" meta1.id meta2.id;
    Alcotest.(check string)
      "durable never downgraded to ephemeral"
      "durable"
      (A.retention_to_wire_string meta2.retention);
    (* Round-trip raw bytes by canonical id and by bare sha256 *)
    (match A.get_bytes store ~id:meta1.id with
     | Ok (Some loaded) -> Alcotest.(check string) "raw bytes match" png loaded
     | Ok None -> Alcotest.fail "missing bytes by id"
     | Error err -> Alcotest.fail (A.get_error_to_string err));
    (match A.get_bytes_by_sha256 store ~sha256:meta1.sha256 with
     | Ok (Some loaded) -> Alcotest.(check string) "raw bytes by sha256" png loaded
     | Ok None -> Alcotest.fail "missing bytes by sha256"
     | Error err -> Alcotest.fail (A.get_error_to_string err));
    (* Tamper detection *)
    let shard = String.sub meta1.sha256 0 2 in
    let bpath =
      Filename.concat
        (Filename.concat (Filename.concat (A.root_dir store) "blobs") shard)
        meta1.sha256
    in
    let oc = open_out_bin bpath in
    output_string oc (png ^ "corrupt");
    close_out oc;
    (match A.get_bytes store ~id:meta1.id with
     | Error (A.Integrity_mismatch _) -> ()
     | Ok _ | Error _ -> Alcotest.fail "expected Integrity_mismatch after tampering");
    (* Re-putting the valid bytes repairs the tampered owned blob file *)
    (match
       A.put
         ~now:1700000060.0
         ~origin:A.User_upload
         ~created_by:"vincent"
         ~retention:A.Durable
         store
         ~bytes:png
     with
     | Ok repaired ->
       Alcotest.(check string) "repaired id" meta1.id repaired.id;
       (match A.get_bytes store ~id:meta1.id with
        | Ok (Some loaded) -> Alcotest.(check string) "repaired bytes match" png loaded
        | Ok None -> Alcotest.fail "missing bytes after repair"
        | Error err -> Alcotest.fail (A.get_error_to_string err))
     | Error err -> Alcotest.fail ("put should repair corrupt owned blob: " ^ A.put_error_to_string err));
    (* Symlink at existing blob path fails closed instead of trusting or overwriting *)
    let external_target = Filename.temp_file "masc_symlink_target_" ".bin" in
    Fun.protect
      ~finally:(fun () -> try Sys.remove external_target with Sys_error _ -> ())
      (fun () ->
         Sys.remove bpath;
         Unix.symlink external_target bpath;
         match
           A.put
             ~now:1700000070.0
             ~origin:A.User_upload
             ~created_by:"vincent"
             ~retention:A.Durable
             store
             ~bytes:png
         with
         | Error (A.Store_io_failed _) -> ()
         | Ok _ | Error _ -> Alcotest.fail "expected Store_io_failed on symlinked blob path");
    Sys.remove bpath;
    (* Restore valid blob then corrupt sidecar JSON: put must fail closed, never silently downgrade *)
    ignore
      (A.put
         ~now:1700000075.0
         ~origin:A.User_upload
         ~created_by:"vincent"
         ~retention:A.Durable
         store
         ~bytes:png
       |> Result.get_ok);
    let mpath =
      Filename.concat
        (Filename.concat (Filename.concat (A.root_dir store) "meta") shard)
        (meta1.sha256 ^ ".json")
    in
    let moc = open_out_bin mpath in
    output_string moc "{not valid json";
    close_out moc;
    match
      A.put
        ~now:1700000080.0
        ~origin:A.Tool_capture
        ~created_by:"keeper"
        ~retention:(A.Ephemeral { keeper = "alpha" })
        store
        ~bytes:png
    with
    | Error (A.Store_io_failed _) -> ()
    | Ok _ | Error _ ->
      Alcotest.fail "expected Store_io_failed when existing metadata sidecar is corrupt")
;;

let test_ephemeral_lru_and_promotion () =
  with_temp_base_path (fun base_path ->
    let store = A.create ~base_path in
    let p1 = make_png ~width:4 ~height:4 ~seed:10 in
    let p2 = make_png ~width:4 ~height:4 ~seed:20 in
    let p3 = make_png ~width:4 ~height:4 ~seed:30 in
    let put_eph ~now bytes =
      match
        A.put
          ~ephemeral_max_entries:2
          ~now
          ~origin:A.Tool_capture
          ~created_by:"keeper:alpha"
          ~retention:(A.Ephemeral { keeper = "alpha" })
          store
          ~bytes
      with
      | Ok m -> m
      | Error err -> Alcotest.fail (A.put_error_to_string err)
    in
    let m1 = put_eph ~now:100.0 p1 in
    let m2 = put_eph ~now:200.0 p2 in
    (* Promote m1 to Durable BEFORE p3 triggers LRU eviction *)
    (match A.promote_to_durable store ~id:m1.id with
     | Ok (Some promoted) ->
       Alcotest.(check string)
         "promoted to durable"
         "durable"
         (A.retention_to_wire_string promoted.retention)
     | Ok None -> Alcotest.fail "promote missing"
     | Error err -> Alcotest.fail (A.get_error_to_string err));
    let m3 = put_eph ~now:300.0 p3 in
    (* p1's ephemeral pin was evicted, BUT its blob MUST survive because it is Durable! *)
    (match A.get_bytes store ~id:m1.id with
     | Ok (Some b) -> Alcotest.(check string) "promoted durable blob survives LRU" p1 b
     | Ok None -> Alcotest.fail "durable blob was wrongly deleted by ephemeral LRU"
     | Error err -> Alcotest.fail (A.get_error_to_string err));
    (* Now add p4 -> m2 (still ephemeral, oldest remaining) must be evicted AND deleted *)
    let p4 = make_png ~width:4 ~height:4 ~seed:40 in
    let m4 = put_eph ~now:400.0 p4 in
    (match A.get_bytes store ~id:m2.id with
     | Ok None -> ()
     | Ok (Some _) -> Alcotest.fail "evicted ephemeral blob should be deleted"
     | Error err -> Alcotest.fail (A.get_error_to_string err));
    match A.list_ephemeral store ~keeper:"alpha" with
    | Ok listed ->
      let ids = List.map (fun (m : A.meta) -> m.id) listed in
      Alcotest.(check (list string)) "newest 2 ephemeral pins remain" [ m4.id; m3.id ] ids
    | Error err -> Alcotest.fail err);
  (* Multi-keeper identical ephemeral capture: both keepers pin same bytes;
     even after first keeper's pin is evicted, second keeper can still read. *)
  with_temp_base_path (fun base_path ->
    let store = A.create ~base_path in
    let shared = make_png ~width:6 ~height:6 ~seed:55 in
    let ma =
      A.put
        ~ephemeral_max_entries:1
        ~now:100.0
        ~origin:A.Tool_capture
        ~created_by:"keeper:alpha"
        ~retention:(A.Ephemeral { keeper = "alpha" })
        store
        ~bytes:shared
      |> Result.get_ok
    in
    let mb =
      A.put
        ~ephemeral_max_entries:2
        ~now:110.0
        ~origin:A.Tool_capture
        ~created_by:"keeper:beta"
        ~retention:(A.Ephemeral { keeper = "beta" })
        store
        ~bytes:shared
      |> Result.get_ok
    in
    Alcotest.(check string) "same id across keepers" ma.id mb.id;
    Alcotest.(check bool) "alpha has pin" true (A.has_ephemeral_pin store ~keeper:"alpha" ~sha256:ma.sha256);
    Alcotest.(check bool) "beta has pin" true (A.has_ephemeral_pin store ~keeper:"beta" ~sha256:ma.sha256);
    Alcotest.(check bool) "gamma has no pin" false (A.has_ephemeral_pin store ~keeper:"gamma" ~sha256:ma.sha256);
    Alcotest.(check bool) "alpha can read" true (A.can_keeper_read store ~keeper:"alpha" ~id_or_sha256:ma.id |> Result.get_ok);
    Alcotest.(check bool) "beta can read" true (A.can_keeper_read store ~keeper:"beta" ~id_or_sha256:ma.id |> Result.get_ok);
    Alcotest.(check bool) "gamma cannot read" false (A.can_keeper_read store ~keeper:"gamma" ~id_or_sha256:ma.id |> Result.get_ok);
    (* Evict alpha's pin by inserting another frame into alpha (max_entries=1) *)
    let other = make_png ~width:6 ~height:6 ~seed:56 in
    ignore
      (A.put
         ~ephemeral_max_entries:1
         ~now:200.0
         ~origin:A.Tool_capture
         ~created_by:"keeper:alpha"
         ~retention:(A.Ephemeral { keeper = "alpha" })
         store
         ~bytes:other
       |> Result.get_ok);
    Alcotest.(check bool) "alpha pin evicted" false (A.has_ephemeral_pin store ~keeper:"alpha" ~sha256:ma.sha256);
    Alcotest.(check bool) "alpha can no longer read" false (A.can_keeper_read store ~keeper:"alpha" ~id_or_sha256:ma.id |> Result.get_ok);
    Alcotest.(check bool) "beta pin survives alpha eviction" true (A.has_ephemeral_pin store ~keeper:"beta" ~sha256:ma.sha256);
    Alcotest.(check bool) "beta can still read after alpha eviction" true (A.can_keeper_read store ~keeper:"beta" ~id_or_sha256:ma.id |> Result.get_ok);
    (match A.get_bytes store ~id:ma.id with
     | Ok (Some b) -> Alcotest.(check string) "shared blob survives alpha eviction" shared b
     | Ok None -> Alcotest.fail "shared blob wrongly deleted while beta still pins it"
     | Error err -> Alcotest.fail (A.get_error_to_string err)));
  (* Fail-closed ephemeral prune (a): corrupt/unreadable meta must NOT delete blob *)
  with_temp_base_path (fun base_path ->
    let store = A.create ~base_path in
    let p1 = make_png ~width:6 ~height:6 ~seed:61 in
    let p2 = make_png ~width:6 ~height:6 ~seed:62 in
    let m1 =
      A.put
        ~ephemeral_max_entries:1
        ~now:100.0
        ~origin:A.Tool_capture
        ~created_by:"keeper:alpha"
        ~retention:(A.Ephemeral { keeper = "alpha" })
        store
        ~bytes:p1
      |> Result.get_ok
    in
    let shard = String.sub m1.sha256 0 2 in
    let mpath =
      Filename.concat
        (Filename.concat (Filename.concat (A.root_dir store) "meta") shard)
        (m1.sha256 ^ ".json")
    in
    let oc = open_out_bin mpath in
    output_string oc "{corrupt meta json";
    close_out oc;
    ignore
      (A.put
         ~ephemeral_max_entries:1
         ~now:200.0
         ~origin:A.Tool_capture
         ~created_by:"keeper:alpha"
         ~retention:(A.Ephemeral { keeper = "alpha" })
         store
         ~bytes:p2
       |> Result.get_ok);
    Alcotest.(check bool) "alpha pin evicted on corrupt meta" false (A.has_ephemeral_pin store ~keeper:"alpha" ~sha256:m1.sha256);
    (match A.get_bytes store ~id:m1.id with
     | Ok (Some b) -> Alcotest.(check string) "blob preserved fail-closed when meta is corrupt" p1 b
     | Ok None -> Alcotest.fail "blob was wrongly deleted despite corrupt metadata"
     | Error err -> Alcotest.fail (A.get_error_to_string err)));
  (* Fail-closed ephemeral prune (b): unreadable sibling keeper dir must NOT delete blob *)
  with_temp_base_path (fun base_path ->
    let store = A.create ~base_path in
    let p1 = make_png ~width:6 ~height:6 ~seed:71 in
    let p2 = make_png ~width:6 ~height:6 ~seed:72 in
    let p_beta = make_png ~width:6 ~height:6 ~seed:73 in
    let m1 =
      A.put
        ~ephemeral_max_entries:1
        ~now:100.0
        ~origin:A.Tool_capture
        ~created_by:"keeper:alpha"
        ~retention:(A.Ephemeral { keeper = "alpha" })
        store
        ~bytes:p1
      |> Result.get_ok
    in
    ignore
      (A.put
         ~ephemeral_max_entries:2
         ~now:105.0
         ~origin:A.Tool_capture
         ~created_by:"keeper:beta"
         ~retention:(A.Ephemeral { keeper = "beta" })
         store
         ~bytes:p_beta
       |> Result.get_ok);
    let beta_dir = Filename.concat (Filename.concat (A.root_dir store) "ephemeral") "beta" in
    Unix.chmod beta_dir 0o000;
    Fun.protect
      ~finally:(fun () -> try Unix.chmod beta_dir 0o700 with Unix.Unix_error _ -> ())
      (fun () ->
         ignore
           (A.put
              ~ephemeral_max_entries:1
              ~now:200.0
              ~origin:A.Tool_capture
              ~created_by:"keeper:alpha"
              ~retention:(A.Ephemeral { keeper = "alpha" })
              store
              ~bytes:p2
            |> Result.get_ok));
    Alcotest.(check bool) "alpha pin evicted while sibling dir unreadable" false (A.has_ephemeral_pin store ~keeper:"alpha" ~sha256:m1.sha256);
    (match A.get_bytes store ~id:m1.id with
     | Ok (Some b) ->
       Alcotest.(check string) "blob preserved fail-closed when sibling keeper dir is unreadable" p1 b
     | Ok None -> Alcotest.fail "blob was wrongly deleted when sibling keeper dir was unreadable"
     | Error err -> Alcotest.fail (A.get_error_to_string err)))
;;

let test_put_opaque_and_fail_closed_pins () =
  with_temp_base_path (fun base_path ->
    let store = A.create ~base_path in
    (* Model-generated unknown format (FLAC) preserved as opaque binary *)
    let meta =
      match
        A.put_opaque
          ~declared_mime:"audio/flac"
          ~filename:"synth.flac"
          ~origin:A.Model_generated
          ~created_by:"keeper:music"
          ~retention:A.Durable
          store
          ~bytes:minimal_flac
      with
      | Ok m -> m
      | Error err -> Alcotest.fail (A.put_error_to_string err)
    in
    Alcotest.(check string) "opaque mime is octet-stream" "application/octet-stream" meta.mime_type;
    Alcotest.(check string) "opaque kind is document" "document" (A.media_kind_to_string meta.kind);
    Alcotest.(check bool) "is_opaque_binary true" true (A.is_opaque_binary meta);
    (match A.get_bytes store ~id:meta.id with
     | Ok (Some loaded) -> Alcotest.(check string) "opaque raw bytes round-trip" minimal_flac loaded
     | Ok None -> Alcotest.fail "missing opaque bytes"
     | Error err -> Alcotest.fail (A.get_error_to_string err));
    (* User_upload is rejected by put_opaque *)
    (match
       A.put_opaque
         ~origin:A.User_upload
         ~created_by:"user"
         ~retention:A.Durable
         store
         ~bytes:minimal_flac
     with
     | Error (A.Unsupported_or_unknown_format _) -> ()
     | Ok _ | Error _ -> Alcotest.fail "put_opaque must reject User_upload");
    (* Active SVG/HTML is still rejected by put_opaque *)
    (match
       A.put_opaque
         ~origin:A.Model_generated
         ~created_by:"keeper"
         ~retention:A.Durable
         store
         ~bytes:"<svg onload='alert(1)'></svg>"
     with
     | Error (A.Forbidden_mime "image/svg+xml") -> ()
     | Ok _ | Error _ -> Alcotest.fail "put_opaque must reject active SVG");
    (* Fail-closed list_all_ephemeral_pins when an ephemeral dir is unreadable *)
    let png = make_png ~width:4 ~height:4 ~seed:88 in
    ignore
      (A.put
         ~origin:A.Tool_capture
         ~created_by:"keeper:locked"
         ~retention:(A.Ephemeral { keeper = "locked" })
         store
         ~bytes:png
       |> Result.get_ok);
    let locked_dir = Filename.concat (Filename.concat (A.root_dir store) "ephemeral") "locked" in
    Unix.chmod locked_dir 0o000;
    Fun.protect
      ~finally:(fun () -> try Unix.chmod locked_dir 0o755 with Unix.Unix_error _ -> ())
      (fun () ->
         match A.list_all_ephemeral_pins store with
         | Error _ -> ()
         | Ok _ -> Alcotest.fail "list_all_ephemeral_pins must fail closed on unreadable dir"))
;;

let test_extract_att_ids () =
  let sha_a = String.make 64 'a' in
  let sha_b = String.make 64 'b' in
  let text =
    Printf.sprintf
      "{\"attachments\":[\"att_%s\"],\"bad\":\"xatt_%s\",\"long\":\"att_%sf\",\"ok\":\"/api/v1/attachments/att_%s\"}"
      sha_a
      sha_b
      sha_b
      sha_b
  in
  let ids = A.extract_att_ids text in
  Alcotest.(check (list string))
    "extracts only valid boundary-checked att ids"
    [ "att_" ^ sha_a; "att_" ^ sha_b ]
    ids;
  let shas = A.referenced_sha256_of_json_text text in
  Alcotest.(check bool) "contains sha_a" true (Set_util.StringSet.mem sha_a shas);
  Alcotest.(check bool) "contains sha_b" true (Set_util.StringSet.mem sha_b shas);
  Alcotest.(check int) "exact count" 2 (Set_util.StringSet.cardinal shas)
;;

let test_derivatives () =
  with_temp_base_path (fun base_path ->
    let store = A.create ~base_path in
    let pdf_meta =
      match
        A.put
          ~origin:A.User_upload
          ~created_by:"u"
          ~retention:A.Durable
          store
          ~bytes:minimal_pdf
      with
      | Ok m -> m
      | Error err -> Alcotest.fail (A.put_error_to_string err)
    in
    (match
       A.get_image_derivative
         ~target_format:A.Force_png
         store
         ~meta:pdf_meta
         ~raw_bytes:minimal_pdf
     with
     | Error (A.Not_an_image "application/pdf") -> ()
     | Ok _ | Error _ -> Alcotest.fail "expected Not_an_image on PDF");
    (* Quantization buckets [160; 320; 640; 1280] *)
    Alcotest.(check int) "quantize 32 -> 160" 160 (A.quantize_thumb_px 32);
    Alcotest.(check int) "quantize 160 -> 160" 160 (A.quantize_thumb_px 160);
    Alcotest.(check int) "quantize 161 -> 320" 320 (A.quantize_thumb_px 161);
    Alcotest.(check int) "quantize 400 -> 640" 640 (A.quantize_thumb_px 400);
    Alcotest.(check int) "quantize 1000 -> 1280" 1280 (A.quantize_thumb_px 1000);
    Alcotest.(check int) "quantize 5000 -> 1280" 1280 (A.quantize_thumb_px 5000);
    (* 240x180 PNG downscaled with max_px=32 snaps to 160px bucket *)
    let png240 = make_png ~width:240 ~height:180 ~seed:99 in
    let png_meta =
      match
        A.put
          ~origin:A.User_upload
          ~created_by:"u"
          ~retention:A.Durable
          store
          ~bytes:png240
      with
      | Ok m -> m
      | Error err -> Alcotest.fail (A.put_error_to_string err)
    in
    (* Force_png on already-PNG with no max_px returns original immediately *)
    (match
       A.get_image_derivative
         ~target_format:A.Force_png
         store
         ~meta:png_meta
         ~raw_bytes:png240
     with
     | Ok (mime, bytes) ->
       Alcotest.(check string) "png identity mime" "image/png" mime;
       Alcotest.(check string) "png identity bytes" png240 bytes
     | Error err -> Alcotest.fail (A.derivative_error_to_string err));
    (* Downscale with max_px=32 -> quantized to 160px bucket & cached at _160.png *)
    match
      A.get_image_derivative
        ~max_px:32
        ~target_format:A.Force_png
        store
        ~meta:png_meta
        ~raw_bytes:png240
    with
    | Ok (mime, scaled) ->
      Alcotest.(check string) "scaled mime" "image/png" mime;
      (match A.detect_image_dimensions scaled with
       | Some (w, h) ->
         Alcotest.(check bool) "scaled <= 160" true (max w h <= 160 && min w h > 0)
       | None -> Alcotest.fail "scaled PNG missing readable dimensions");
      (* A corrupt cached derivative is replaced, not served or refused. *)
      let cache_path =
        Filename.concat
          (Filename.concat
             (Filename.concat (A.root_dir store) "thumbs")
             (String.sub png_meta.sha256 0 2))
          (png_meta.sha256 ^ "_160.png")
      in
      Alcotest.(check bool) "derivative was cached under quantized _160.png" true (Sys.file_exists cache_path);
      let oc = open_out_bin cache_path in
      output_string oc "not an image";
      close_out oc;
      (match
         A.get_image_derivative
           ~max_px:32
           ~target_format:A.Force_png
           store
           ~meta:png_meta
           ~raw_bytes:png240
       with
       | Ok (mime2, regenerated) ->
         Alcotest.(check string) "regenerated mime" "image/png" mime2;
         Alcotest.(check bool)
           "regenerated bytes are a PNG"
           true
           (A.sniff_mime regenerated = Some A.Image_png)
       | Error err ->
         Alcotest.fail
           ("corrupt cache was not regenerated: " ^ A.derivative_error_to_string err));
      (* A wrong-format cached image (valid GIF sitting at *.png) is also rejected and regenerated as PNG. *)
      let goc = open_out_bin cache_path in
      output_string goc valid_1x1_gif;
      close_out goc;
      (match
         A.get_image_derivative
           ~max_px:32
           ~target_format:A.Force_png
           store
           ~meta:png_meta
           ~raw_bytes:png240
       with
       | Ok (mime3, regen_png) ->
         Alcotest.(check string) "wrong-format cache replaced with png" "image/png" mime3;
         Alcotest.(check bool)
           "wrong-format cache regenerated bytes are PNG"
           true
           (A.sniff_mime regen_png = Some A.Image_png)
       | Error err ->
         Alcotest.fail
           ("wrong-format cache was not regenerated: " ^ A.derivative_error_to_string err));
      (* Transcode non-PNG (valid 1x1 GIF) -> PNG via Force_png *)
      let gif_meta =
        A.put
          ~origin:A.User_upload
          ~created_by:"u"
          ~retention:A.Durable
          store
          ~bytes:valid_1x1_gif
        |> Result.get_ok
      in
      (match
         A.get_image_derivative
           ~target_format:A.Force_png
           store
           ~meta:gif_meta
           ~raw_bytes:valid_1x1_gif
       with
       | Ok (gif_out_mime, gif_as_png) ->
         Alcotest.(check string) "gif->png mime" "image/png" gif_out_mime;
         Alcotest.(check bool)
           "gif->png bytes sniff as PNG"
           true
           (A.sniff_mime gif_as_png = Some A.Image_png)
       | Error err ->
         Alcotest.fail ("gif->png transcode failed: " ^ A.derivative_error_to_string err))
    | Error err -> Alcotest.fail (A.derivative_error_to_string err))
;;

let generate_tiny_mp4_opt () =
  let out = Filename.temp_file "masc_test_vid_" ".mp4" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove out with Sys_error _ -> ())
    (fun () ->
       match
         Process_eio.run_argv_with_status_split_or_refusal
           ~timeout_sec:10.0
           [ "ffmpeg"
           ; "-nostdin"
           ; "-hide_banner"
           ; "-loglevel"
           ; "error"
           ; "-y"
           ; "-f"
           ; "lavfi"
           ; "-i"
           ; "color=c=blue:s=320x240:d=0.2:r=5"
           ; "-pix_fmt"
           ; "yuv420p"
           ; "-movflags"
           ; "+faststart"
           ; out
           ]
       with
       | Ok (Unix.WEXITED 0, _, _) when Sys.file_exists out ->
         let ic = open_in_bin out in
         let bytes =
           Fun.protect
             ~finally:(fun () -> close_in_noerr ic)
             (fun () -> really_input_string ic (in_channel_length ic))
         in
         if String.length bytes > 0 then Some bytes else None
       | _ -> None)
;;

let test_video_aliases_limits_and_poster () =
  Eio_main.run @@ fun env ->
  Process_eio.init
    ~cwd_default:env#cwd
    ~proc_mgr:env#process_mgr
    ~clock:env#clock;
  with_temp_base_path (fun base_path ->
    let store = A.create ~base_path in
    let put ?declared_mime bytes =
      A.put
        ?declared_mime
        ~origin:A.User_upload
        ~created_by:"u"
        ~retention:A.Durable
        store
        ~bytes
    in
    (* Declared MIME aliases normalize cleanly *)
    let m_midi1 = put ~declared_mime:"audio/x-midi" minimal_midi |> Result.get_ok in
    Alcotest.(check string) "audio/x-midi -> audio/midi" "audio/midi" m_midi1.mime_type;
    let m_midi2 = put ~declared_mime:"audio/mid" minimal_midi |> Result.get_ok in
    Alcotest.(check string) "audio/mid -> audio/midi" "audio/midi" m_midi2.mime_type;
    let m_wav1 = put ~declared_mime:"audio/x-wav" minimal_wav |> Result.get_ok in
    Alcotest.(check string) "audio/x-wav -> audio/wav" "audio/wav" m_wav1.mime_type;
    let m_wav2 = put ~declared_mime:"audio/wave" minimal_wav |> Result.get_ok in
    Alcotest.(check string) "audio/wave -> audio/wav" "audio/wav" m_wav2.mime_type;
    let m_m4v = put ~declared_mime:"video/x-m4v" minimal_m4v_video |> Result.get_ok in
    Alcotest.(check string) "video/x-m4v -> video/mp4" "video/mp4" m_m4v.mime_type;
    Alcotest.(check string) "video kind wire string" "video" (A.media_kind_to_string m_m4v.kind);
    (* Default video limit is 50 MiB vs 20 MiB non-video *)
    Alcotest.(check int) "default_max_bytes 20MiB" (20 * 1024 * 1024) A.default_max_bytes;
    Alcotest.(check int) "default_max_video_bytes 50MiB" (50 * 1024 * 1024) A.default_max_video_bytes;
    (* Separate env size caps: video allowed above MASC_ATTACHMENT_MAX_BYTES up to MASC_ATTACHMENT_MAX_VIDEO_BYTES *)
    let prev_max = Sys.getenv_opt "MASC_ATTACHMENT_MAX_BYTES" in
    let prev_vid = Sys.getenv_opt "MASC_ATTACHMENT_MAX_VIDEO_BYTES" in
    let restore_env k = function
      | Some v -> Unix.putenv k v
      | None -> Unix.putenv k ""
    in
    Unix.putenv "MASC_ATTACHMENT_MAX_BYTES" "64";
    Unix.putenv "MASC_ATTACHMENT_MAX_VIDEO_BYTES" "256";
    Fun.protect
      ~finally:(fun () ->
        restore_env "MASC_ATTACHMENT_MAX_BYTES" prev_max;
        restore_env "MASC_ATTACHMENT_MAX_VIDEO_BYTES" prev_vid)
      (fun () ->
         let big_png = make_png ~width:16 ~height:16 ~seed:5 in
         Alcotest.(check bool) "big_png > 64 bytes" true (String.length big_png > 64);
         (match put ~declared_mime:"image/png" big_png with
          | Error (A.Payload_too_large { maximum = 64; _ }) -> ()
          | Ok _ | Error _ -> Alcotest.fail "expected non-video rejected at 64 bytes");
         let vid_128 = minimal_m4v_video ^ String.make 100 '\x00' in
         (match put ~declared_mime:"video/mp4" vid_128 with
          | Ok m -> Alcotest.(check string) "128B video accepted under 256B video cap" "video/mp4" m.mime_type
          | Error err -> Alcotest.fail ("expected video accepted under video cap: " ^ A.put_error_to_string err));
         let vid_300 = minimal_m4v_video ^ String.make 280 '\x00' in
         (match put ~declared_mime:"video/mp4" vid_300 with
          | Error (A.Payload_too_large { maximum = 256; _ }) -> ()
          | Ok _ | Error _ -> Alcotest.fail "expected 300B video rejected at 256B video cap"));
    (* Corrupt video poster fails cleanly with Transform_failed *)
    (match A.get_video_poster ~max_px:160 store ~meta:m_m4v ~raw_bytes:minimal_m4v_video with
     | Error (A.Transform_failed _) -> ()
     | Ok _ | Error _ -> Alcotest.fail "expected Transform_failed on truncated MP4");
    (* Non-video rejected with Not_an_image *)
    (match A.get_video_poster store ~meta:m_midi1 ~raw_bytes:minimal_midi with
     | Error (A.Not_an_image "audio/midi") -> ()
     | Ok _ | Error _ -> Alcotest.fail "expected Not_an_image on MIDI");
    (* get_byte_range reads exact slice via seek_in and rejects out-of-bounds/negative *)
    (match A.get_byte_range store ~id:m_midi1.id ~start:0 ~length:4 with
     | Ok (Some slice) -> Alcotest.(check string) "get_byte_range head" "MThd" slice
     | Ok None | Error _ -> Alcotest.fail "expected MThd head slice");
    (match A.get_byte_range store ~id:m_midi1.id ~start:4 ~length:4 with
     | Ok (Some slice) ->
       Alcotest.(check string) "get_byte_range mid" (String.sub minimal_midi 4 4) slice
     | Ok None | Error _ -> Alcotest.fail "expected mid slice");
    (match A.get_byte_range store ~id:m_midi1.id ~start:0 ~length:(String.length minimal_midi + 1) with
     | Error (A.Read_failed _) -> ()
     | Ok _ | Error _ -> Alcotest.fail "expected Read_failed for out-of-bounds range");
    (match A.get_byte_range store ~id:m_midi1.id ~start:(-1) ~length:2 with
     | Error (A.Read_failed _) -> ()
     | Ok _ | Error _ -> Alcotest.fail "expected Read_failed for negative start");
    (* Real ffmpeg MP4 poster extraction when ffmpeg is installed *)
    match generate_tiny_mp4_opt () with
    | None -> ()
    | Some mp4_bytes ->
      let mp4_meta = put ~declared_mime:"video/mp4" mp4_bytes |> Result.get_ok in
      Alcotest.(check string) "real mp4 kind" "video" (A.media_kind_to_string mp4_meta.kind);
      (match A.get_video_poster ~max_px:160 store ~meta:mp4_meta ~raw_bytes:mp4_bytes with
       | Error err -> Alcotest.fail ("get_video_poster failed: " ^ A.derivative_error_to_string err)
       | Ok (mime, poster_png) ->
         Alcotest.(check string) "poster mime" "image/png" mime;
         Alcotest.(check bool) "poster sniffs as PNG" true (A.sniff_mime poster_png = Some A.Image_png);
         (match A.detect_image_dimensions poster_png with
          | Some (w, h) -> Alcotest.(check bool) "poster <= 160px" true (max w h <= 160 && min w h > 0)
          | None -> Alcotest.fail "poster PNG dimensions unreadable");
         let cache_path =
           Filename.concat
             (Filename.concat
                (Filename.concat (A.root_dir store) "thumbs")
                (String.sub mp4_meta.sha256 0 2))
             (mp4_meta.sha256 ^ "_poster_160.png")
         in
         Alcotest.(check bool) "poster cached at _poster_160.png" true (Sys.file_exists cache_path));
      (* get_image_derivative ~target_format:Force_png on Video delegates to get_video_poster *)
      (match
         A.get_image_derivative
           ~max_px:160
           ~target_format:A.Force_png
           store
           ~meta:mp4_meta
           ~raw_bytes:mp4_bytes
       with
       | Ok (mime, png2) ->
         Alcotest.(check string) "derivative video->png mime" "image/png" mime;
         Alcotest.(check bool) "derivative video->png sniffs PNG" true (A.sniff_mime png2 = Some A.Image_png)
       | Error err -> Alcotest.fail ("video Force_png failed: " ^ A.derivative_error_to_string err)))
;;

let () =
  Alcotest.run
    "attachment_store"
    [ ( "attachment_store"
      , [ Alcotest.test_case "magic sniffing and raster dimensions" `Quick test_magic_sniffing_and_dimensions
        ; Alcotest.test_case "security rejections (SVG/HTML/spoof/size/empty)" `Quick test_security_rejections
        ; Alcotest.test_case "put dedup wire JSON and integrity verification" `Quick test_put_dedup_wire_json_and_integrity
        ; Alcotest.test_case "ephemeral LRU pruning, multi-keeper pins, and promotion" `Quick test_ephemeral_lru_and_promotion
        ; Alcotest.test_case "put_opaque binary preservation and fail-closed pin scan" `Quick test_put_opaque_and_fail_closed_pins
        ; Alcotest.test_case "extract_att_ids boundary scanning" `Quick test_extract_att_ids
        ; Alcotest.test_case "image derivatives and non-image refusal" `Quick test_derivatives
        ; Alcotest.test_case "video MIME aliases, 50MiB limit, and ffmpeg poster frame" `Quick test_video_aliases_limits_and_poster
        ] )
    ]
;;
