(* RFC-0301: unit tests for the content-addressed generated-media store. *)

module M = Masc.Keeper_chat_media_store

let with_temp_base f =
  let base = Filename.temp_dir "media_store_test" "" in
  f base

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let expected_token ~media_type data =
  Digestif.SHA256.(
    digest_string (String.lowercase_ascii (String.trim media_type) ^ "\000" ^ data)
    |> to_hex)

let test_persist_round_trip () =
  with_temp_base (fun base_dir ->
    let data = "\137PNG\r\n fake-image-bytes \000\255" in
    let token, url = M.persist ~base_dir ~media_type:"image/png" ~data in
    Alcotest.(check string)
      "url is /api/v1/media/<token>"
      ("/api/v1/media/" ^ token)
      url;
    Alcotest.(check bool) "token has valid shape" true (M.valid_token token);
    Alcotest.(check int) "token is SHA-256 hex" 64 (String.length token);
    match M.file_path_of_token ~base_dir ~token with
    | None -> Alcotest.fail "persisted media not found by token"
    | Some path ->
      Alcotest.(check string) "round-trip bytes preserved" data (read_file path);
      Alcotest.(check string)
        "content-type derived from stored extension"
        "image/png"
        (M.content_type_of_path path))

let test_content_addressed_dedup () =
  with_temp_base (fun base_dir ->
    let data = "identical-payload-bytes" in
    let t1, _ = M.persist ~base_dir ~media_type:"audio/mpeg" ~data in
    let t2, _ = M.persist ~base_dir ~media_type:"audio/mpeg" ~data in
    Alcotest.(check string) "identical payload dedups to one token" t1 t2)

let test_same_bytes_different_media_type_get_distinct_tokens () =
  with_temp_base (fun base_dir ->
    let data = "same-bytes" in
    let image_token, _ = M.persist ~base_dir ~media_type:"image/png" ~data in
    let audio_token, _ = M.persist ~base_dir ~media_type:"audio/mpeg" ~data in
    Alcotest.(check bool)
      "different media types do not share one extensionless token"
      true
      (not (String.equal image_token audio_token)))

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

let media_category_testable =
  Alcotest.testable
    (fun ppf c ->
      Format.pp_print_string ppf
        (match c with
         | M.Image -> "Image"
         | M.Audio -> "Audio"
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
    let raw = "raw image bytes" in
    let encoded = Base64.encode_string raw in
    match
      M.persist_media_source_result ~base_dir ~media_type:"image/png"
        ~source_type:Agent_sdk.Types.Base64 ~data:encoded
    with
    | Error err ->
        Alcotest.failf "unexpected persist error: %s" (M.persist_error_to_string err)
    | Ok (token, url) ->
        Alcotest.(check string)
          "token is derived from decoded raw bytes"
          (expected_token ~media_type:"image/png" raw)
          token;
        Alcotest.(check string) "url" ("/api/v1/media/" ^ token) url;
        (match M.file_path_of_token ~base_dir ~token with
         | None -> Alcotest.fail "persisted decoded media not found"
         | Some path ->
             Alcotest.(check string) "stored raw bytes" raw (read_file path)))

let test_unsupported_source_type_rejected () =
  with_temp_base (fun base_dir ->
    match
      M.persist_media_source_result ~base_dir ~media_type:"image/png"
        ~source_type:Agent_sdk.Types.Url ~data:"https://example.invalid/image.png"
    with
    | Ok _ -> Alcotest.fail "url source must not be persisted without resolver"
    | Error (M.Unsupported_source_type Agent_sdk.Types.Url) -> ()
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
        ; Alcotest.test_case "media_type mapping" `Quick test_media_type_mapping
        ; Alcotest.test_case "media category" `Quick test_media_category
        ; Alcotest.test_case
            "base64 source decoded"
            `Quick
            test_base64_source_decoded_before_persist
        ; Alcotest.test_case
            "unsupported source rejected"
            `Quick
            test_unsupported_source_type_rejected
        ] )
    ]
