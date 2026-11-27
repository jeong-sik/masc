(* Unit tests for the content-addressed generated-media store. *)

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

let with_temp_base f =
  let base = Filename.temp_dir "media_store_test" "" in
  f base

let write_file path data =
  let oc = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc data)

let expected_token data =
  Agent_core_sha256.(digest_string data |> to_hex)

let expected_url data =
  "/api/v1/attachments/att_" ^ expected_token data

let valid_png suffix = "\x89PNG\r\n\x1a\n" ^ suffix
let valid_mp3 suffix = "ID3\x03\x00\x00\x00" ^ suffix
let valid_midi suffix = "MThd\x00\x00\x00\x06" ^ suffix

let persist_ok ~base_dir ~media_type ~data =
  match M.persist_result ~base_dir ~media_type ~data with
  | Ok stored -> stored
  | Error message -> Alcotest.failf "unexpected persist error: %s" message

let test_persist_round_trip () =
  with_temp_base (fun base_dir ->
    let data = valid_png "fake-image-bytes \000\255" in
    let token, url = persist_ok ~base_dir ~media_type:"image/png" ~data in
    Alcotest.(check string)
      "url is /api/v1/attachments/att_<token>"
      ("/api/v1/attachments/att_" ^ token)
      url;
    Alcotest.(check bool) "token has valid shape" true (M.valid_token token);
    Alcotest.(check int) "token is SHA-256 hex" 64 (String.length token);
    let store = Attachment_store.create ~base_path:base_dir in
    match Attachment_store.get_bytes_by_sha256 store ~sha256:token with
    | Ok (Some stored) ->
      Alcotest.(check string) "round-trip bytes preserved" data stored
    | Ok None -> Alcotest.fail "persisted media not found in Attachment_store"
    | Error err -> Alcotest.fail (Attachment_store.get_error_to_string err))

let test_content_addressed_dedup () =
  with_temp_base (fun base_dir ->
    let data = valid_mp3 "identical-payload-bytes" in
    let t1, _ = persist_ok ~base_dir ~media_type:"audio/mpeg" ~data in
    let t2, _ = persist_ok ~base_dir ~media_type:"audio/mpeg" ~data in
    Alcotest.(check string) "identical payload dedups to one token" t1 t2)

let test_same_bytes_different_media_type_get_distinct_tokens () =
  with_temp_base (fun base_dir ->
    let png = valid_png "sample" in
    let mp3 = valid_mp3 "sample" in
    let image_token, image_url = persist_ok ~base_dir ~media_type:"image/png" ~data:png in
    let audio_token, audio_url = persist_ok ~base_dir ~media_type:"audio/mpeg" ~data:mp3 in
    Alcotest.(check bool)
      "distinct binary payloads get distinct attachment tokens"
      true
      (not (String.equal image_token audio_token));
    Alcotest.(check string) "image canonical url" (expected_url png) image_url;
    Alcotest.(check string) "audio canonical url" (expected_url mp3) audio_url;
    (* Mislabeled declared MIME falls back to magic-byte sniffing instead of dropping. *)
    let sniffed_token, _ = persist_ok ~base_dir ~media_type:"audio/mpeg" ~data:png in
    Alcotest.(check string) "mislabeled png dedups to verified png sha256" image_token sniffed_token)

let test_unknown_token_absent () =
  with_temp_base (fun base_dir ->
    Alcotest.(check bool)
      "malformed token rejected"
      false
      (M.valid_token "not a token");
    Alcotest.(check (option string))
      "absent token resolves to None"
      None
      (M.file_path_of_token ~base_dir ~token:(String.make 64 '0')))

let test_token_lookup_probes_known_extensions_without_scan () =
  with_temp_base (fun base_dir ->
    let token = String.make 64 'b' in
    let unsupported_token = String.make 64 'c' in
    let media_dir =
      Filename.concat (Common.masc_dir_from_base_path ~base_path:base_dir) "media"
    in
    Fs_compat.mkdir_p media_dir;
    let bin_path = Filename.concat media_dir (token ^ ".bin") in
    let png_path = Filename.concat media_dir (token ^ ".png") in
    let txt_path = Filename.concat media_dir (unsupported_token ^ ".txt") in
    write_file bin_path "bin";
    write_file png_path "png";
    write_file txt_path "txt";
    Alcotest.(check (option string))
      "known ext wins over bin fallback"
      (Some png_path)
      (M.file_path_of_token ~base_dir ~token);
    Alcotest.(check (option string))
      "unsupported extension is not resolved"
      None
      (M.file_path_of_token ~base_dir ~token:unsupported_token))

let test_media_type_mapping () =
  Alcotest.(check string) "png ext" "png" (M.ext_of_media_type "image/png");
  Alcotest.(check string) "mp3 ext" "mp3" (M.ext_of_media_type "audio/mpeg");
  Alcotest.(check string)
    "unknown media type falls back to bin"
    "bin"
    (M.ext_of_media_type "application/x-unknown");
  Alcotest.(check string) "png content-type" "image/png" (M.content_type_of_ext "png");
  Alcotest.(check string)
    "unknown ext content-type"
    "application/octet-stream"
    (M.content_type_of_ext "bin");
  (* jpg canonicalizes to image/jpeg, mp3 to audio/mpeg (SSOT table first-wins). *)
  Alcotest.(check string) "jpg content-type" "image/jpeg" (M.content_type_of_ext "jpg");
  Alcotest.(check string) "mp3 content-type" "audio/mpeg" (M.content_type_of_ext "mp3")

let test_persist_publishes_current_midi_type () =
  with_temp_base (fun base_dir ->
    let data = valid_midi "\000original MIDI bytes" in
    let media_type = "audio/midi" in
    let token = expected_token data in
    let regenerated, url = persist_ok ~base_dir ~media_type ~data in
    Alcotest.(check string) "MIDI token is content SHA-256" token regenerated;
    Alcotest.(check string) "MIDI url is canonical attachment URL"
      ("/api/v1/attachments/att_" ^ token) url;
    let store = Attachment_store.create ~base_path:base_dir in
    match Attachment_store.get_meta store ~id:("att_" ^ token) with
    | Ok (Some meta) ->
      Alcotest.(check string) "Attachment_store records canonical MIDI mime"
        "audio/midi" meta.mime_type;
      (match Attachment_store.get_bytes_by_sha256 store ~sha256:token with
       | Ok (Some stored) ->
         Alcotest.(check string) "canonical publication retains complete original bytes"
           data stored
       | Ok None -> Alcotest.fail "stored MIDI bytes missing"
       | Error err -> Alcotest.fail (Attachment_store.get_error_to_string err))
    | Ok None -> Alcotest.fail "regenerated MIDI meta missing"
    | Error err -> Alcotest.fail (Attachment_store.get_error_to_string err))

let media_category_testable =
  Alcotest.testable
    (fun ppf c ->
      Format.pp_print_string ppf
        (match c with
         | M.Image -> "Image"
         | M.Audio -> "Audio"
         | M.Midi -> "Midi"
         | M.Document -> "Document"
         | M.Other -> "Other"))
    ( = )

let test_media_category () =
  let check = Alcotest.(check media_category_testable) in
  check "png is Image" M.Image (M.category_of_media_type "image/png");
  check "jpeg is Image" M.Image (M.category_of_media_type "image/jpeg");
  check "mp3 is Audio" M.Audio (M.category_of_media_type "audio/mpeg");
  check "wav is Audio" M.Audio (M.category_of_media_type "audio/wav");
  check "pdf is Document" M.Document (M.category_of_media_type "application/pdf");
  check "unknown is Other" M.Other (M.category_of_media_type "application/x-unknown")

let test_base64_source_decoded_before_persist () =
  with_temp_base (fun base_dir ->
    let raw = valid_png "raw image bytes" in
    let encoded = Base64.encode_string raw in
    match
      M.persist_media_source_result ~base_dir ~media_type:"image/png"
        ~source:(Llm_provider.Types.Base64 encoded)
    with
    | Error err ->
        Alcotest.failf "unexpected persist error: %s" (M.persist_error_to_string err)
    | Ok (token, url) ->
        Alcotest.(check string)
          "token is derived from decoded raw bytes"
          (expected_token raw)
          token;
        Alcotest.(check string) "url" ("/api/v1/attachments/att_" ^ token) url;
        let store = Attachment_store.create ~base_path:base_dir in
        (match Attachment_store.get_bytes_by_sha256 store ~sha256:token with
         | Ok (Some stored) ->
             Alcotest.(check string) "stored raw bytes" raw stored
         | Ok None -> Alcotest.fail "persisted decoded media not found"
         | Error err -> Alcotest.fail (Attachment_store.get_error_to_string err)))

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
        M.persist_media_source_result ~base_dir ~media_type:"image/png"
          ~source:(Llm_provider.Types.Base64 (Base64.encode_string raw))
      with
      | Ok _ -> Alcotest.fail "oversize decoded media must not be persisted"
      | Error (M.Media_too_large { size_bytes; max_bytes }) ->
          Alcotest.(check int) "size bytes" 5 size_bytes;
          Alcotest.(check int) "max bytes" 4 max_bytes
      | Error err ->
          Alcotest.failf "unexpected error: %s" (M.persist_error_to_string err)))

let test_persist_runs_opportunistic_media_cleanup () =
  with_temp_base (fun base_dir ->
    let seed = valid_png "seed" in
    let fresh = valid_png "fresh" in
    let seed_token, _ =
      persist_ok ~base_dir ~media_type:"image/png" ~data:seed
    in
    let fresh_token, _ =
      persist_ok ~base_dir ~media_type:"image/png" ~data:fresh
    in
    let store = Attachment_store.create ~base_path:base_dir in
    (match Attachment_store.get_meta store ~id:("att_" ^ seed_token) with
     | Ok (Some meta) ->
       Alcotest.(check string) "generated media is durable" "durable"
         (Attachment_store.retention_to_wire_string meta.retention)
     | Ok None -> Alcotest.fail "seed media missing"
     | Error err -> Alcotest.fail (Attachment_store.get_error_to_string err));
    match Attachment_store.get_bytes_by_sha256 store ~sha256:fresh_token with
    | Ok (Some stored) -> Alcotest.(check string) "fresh media readable" fresh stored
    | Ok None -> Alcotest.fail "fresh media missing"
    | Error err -> Alcotest.fail (Attachment_store.get_error_to_string err))

let test_persist_preserves_opaque_non_allowlisted_media () =
  with_temp_base (fun base_dir ->
    let flac = "fLaC\x00\x00\x00\x22opaque-flac-audio-bytes" in
    let flac_token, flac_url =
      persist_ok ~base_dir ~media_type:"audio/flac" ~data:flac
    in
    Alcotest.(check string) "opaque flac canonical url" (expected_url flac) flac_url;
    let unknown = "\x01\x02\x03custom-model-binary-output" in
    let unk_token, unk_url =
      persist_ok ~base_dir ~media_type:"application/x-unknown" ~data:unknown
    in
    Alcotest.(check string) "opaque unknown canonical url" (expected_url unknown) unk_url;
    let store = Attachment_store.create ~base_path:base_dir in
    List.iter
      (fun (label, token, expected) ->
         (match Attachment_store.get_meta store ~id:("att_" ^ token) with
          | Ok (Some meta) ->
            Alcotest.(check bool) (label ^ " stored as opaque binary") true
              (Attachment_store.is_opaque_binary meta);
            Alcotest.(check string) (label ^ " mime is application/octet-stream")
              "application/octet-stream" meta.mime_type;
            Alcotest.(check string) (label ^ " origin is model_generated")
              "model_generated" (Attachment_store.origin_to_string meta.origin)
          | Ok None -> Alcotest.fail (label ^ " meta missing")
          | Error err -> Alcotest.fail (Attachment_store.get_error_to_string err));
         match Attachment_store.get_bytes_by_sha256 store ~sha256:token with
         | Ok (Some stored) ->
           Alcotest.(check string) (label ^ " exact bytes round-trip") expected stored
         | Ok None -> Alcotest.fail (label ^ " bytes missing")
         | Error err -> Alcotest.fail (Attachment_store.get_error_to_string err))
      [ "flac", flac_token, flac; "unknown", unk_token, unknown ];
    Alcotest.(check string) "audio/mp4 ext" "m4a" (M.ext_of_media_type "audio/mp4");
    Alcotest.(check string) "audio/webm ext" "webm" (M.ext_of_media_type "audio/webm");
    Alcotest.(check media_category_testable) "audio/mp4 is Audio" M.Audio
      (M.category_of_media_type "audio/mp4");
    Alcotest.(check media_category_testable) "audio/webm is Audio" M.Audio
      (M.category_of_media_type "audio/webm"))

let test_unsupported_source_type_rejected () =
  with_temp_base (fun base_dir ->
    match
      M.persist_media_source_result ~base_dir ~media_type:"image/png"
        ~source:(Llm_provider.Types.Url "https://example.invalid/image.png")
    with
    | Ok _ -> Alcotest.fail "url source must not be persisted without resolver"
    | Error (M.Unsupported_source_type Agent_core.Types.Url_kind) -> ()
    | Error err ->
        Alcotest.failf "unexpected error: %s" (M.persist_error_to_string err))

let () =
  Alcotest.run
    "keeper_chat_media_store"
    [ ( "media_store"
      , [ Alcotest.test_case "persist round-trip" `Quick test_persist_round_trip
        ; Alcotest.test_case
            "content-addressed dedup"
            `Quick
            test_content_addressed_dedup
        ; Alcotest.test_case
            "same bytes different media type"
            `Quick
            test_same_bytes_different_media_type_get_distinct_tokens
        ; Alcotest.test_case "unknown token absent" `Quick test_unknown_token_absent
        ; Alcotest.test_case
            "token lookup probes known extensions"
            `Quick
            test_token_lookup_probes_known_extensions_without_scan
        ; Alcotest.test_case "media_type mapping" `Quick test_media_type_mapping
        ; Alcotest.test_case "regeneration publishes current MIDI type" `Quick
            test_persist_publishes_current_midi_type
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
            "persist runs opportunistic media cleanup"
            `Quick
            test_persist_runs_opportunistic_media_cleanup
        ; Alcotest.test_case
            "opaque non-allowlisted generated media preserved via Attachment_store.put_opaque"
            `Quick
            test_persist_preserves_opaque_non_allowlisted_media
        ; Alcotest.test_case
            "unsupported source rejected"
            `Quick
            test_unsupported_source_type_rejected
        ] )
    ]
