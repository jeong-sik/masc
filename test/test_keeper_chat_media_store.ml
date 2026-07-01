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

let test_persist_round_trip () =
  with_temp_base (fun base_dir ->
    let data = "\137PNG\r\n fake-image-bytes \000\255" in
    let token, url = M.persist ~base_dir ~media_type:"image/png" ~data in
    Alcotest.(check string)
      "url is /api/v1/media/<token>"
      ("/api/v1/media/" ^ token)
      url;
    Alcotest.(check bool) "token has valid shape" true (M.valid_token token);
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

let test_unknown_token_absent () =
  with_temp_base (fun base_dir ->
    Alcotest.(check bool)
      "malformed token rejected"
      false
      (M.valid_token "not a token");
    Alcotest.(check (option string))
      "absent token resolves to None"
      None
      (M.file_path_of_token ~base_dir ~token:"deadbeefdeadbeefdeadbeefdeadbeef"))

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
    (M.content_type_of_ext "bin")

let () =
  Alcotest.run
    "keeper_chat_media_store"
    [ ( "media_store"
      , [ Alcotest.test_case "persist round-trip" `Quick test_persist_round_trip
        ; Alcotest.test_case
            "content-addressed dedup"
            `Quick
            test_content_addressed_dedup
        ; Alcotest.test_case "unknown token absent" `Quick test_unknown_token_absent
        ; Alcotest.test_case "media_type mapping" `Quick test_media_type_mapping
        ] )
    ]
