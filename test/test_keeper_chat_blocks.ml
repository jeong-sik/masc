module B = Masc.Keeper_chat_blocks

let yojson_testable =
  Alcotest.testable
    (fun fmt json -> Format.fprintf fmt "%s" (Yojson.Safe.to_string json))
    ( = )

let blocks_to_json_list blocks =
  match B.blocks_to_yojson blocks with
  | `List items -> items
  | _ -> []

let test_plain_text_becomes_escaped_text_block () =
  let blocks = B.parse_text_to_blocks "hello <world>" in
  Alcotest.(check int) "one block" 1 (List.length blocks);
  Alcotest.(check (list yojson_testable))
    "escaped html"
    [ `Assoc [ ("t", `String "p"); ("html", `String "hello &lt;world&gt;") ] ]
    (blocks_to_json_list blocks)

let test_markdown_image_and_surrounding_text () =
  let blocks = B.parse_text_to_blocks "before ![alt text](https://example.com/a.png) after" in
  Alcotest.(check (list yojson_testable))
    "image with surrounding text"
    [
      `Assoc [ ("t", `String "p"); ("html", `String "before ") ];
      `Assoc
        [
          ("t", `String "image");
          ("src", `String "https://example.com/a.png");
          ("cap", `String "alt text");
        ];
      `Assoc [ ("t", `String "p"); ("html", `String " after") ];
    ]
    (blocks_to_json_list blocks)

let test_bare_image_url_on_own_line () =
  let blocks = B.parse_text_to_blocks "https://example.com/screen.webp" in
  Alcotest.(check (list yojson_testable))
    "image block"
    [ `Assoc [ ("t", `String "image"); ("src", `String "https://example.com/screen.webp") ] ]
    (blocks_to_json_list blocks)

let test_standalone_non_image_url_becomes_link () =
  let blocks = B.parse_text_to_blocks "https://example.com/post" in
  Alcotest.(check (list yojson_testable))
    "link block"
    [
      `Assoc
        [
          ("t", `String "link");
          ("url", `String "https://example.com/post");
          ("title", `String "example.com");
          ("meta", `String "example.com");
        ];
    ]
    (blocks_to_json_list blocks)

let test_inline_url_stays_in_text () =
  let blocks = B.parse_text_to_blocks "See https://example.com for more." in
  Alcotest.(check (list yojson_testable))
    "text block keeps inline url"
    [ `Assoc [ ("t", `String "p"); ("html", `String "See https://example.com for more.") ] ]
    (blocks_to_json_list blocks)

let test_multiple_images_and_text_lines () =
  let blocks = B.parse_text_to_blocks "intro\n![a](https://x.com/1.jpg)\nhttps://x.com/2.gif\noutro" in
  Alcotest.(check (list yojson_testable))
    "mixed blocks in order"
    [
      `Assoc [ ("t", `String "p"); ("html", `String "intro") ];
      `Assoc [ ("t", `String "image"); ("src", `String "https://x.com/1.jpg"); ("cap", `String "a") ];
      `Assoc [ ("t", `String "image"); ("src", `String "https://x.com/2.gif") ];
      `Assoc [ ("t", `String "p"); ("html", `String "outro") ];
    ]
    (blocks_to_json_list blocks)

let test_empty_lines_ignored () =
  let blocks = B.parse_text_to_blocks "line1\n\nline2" in
  Alcotest.(check int) "two blocks" 2 (List.length blocks);
  Alcotest.(check (list string)) "text order"
    [ "line1"; "line2" ]
    (List.map
       (fun block ->
          match B.block_to_yojson block with
          | `Assoc fields -> (
              match List.assoc_opt "html" fields with
              | Some (`String s) -> s
              | _ -> "")
          | _ -> "")
       blocks)

let test_link_without_www () =
  let blocks = B.parse_text_to_blocks "https://www.example.com/post" in
  Alcotest.(check (list yojson_testable))
    "www stripped"
    [
      `Assoc
        [
          ("t", `String "link");
          ("url", `String "https://www.example.com/post");
          ("title", `String "example.com");
          ("meta", `String "example.com");
        ];
    ]
    (blocks_to_json_list blocks)

let test_blocks_of_yojson_roundtrip () =
  let original = B.parse_text_to_blocks "text\n![a](https://x.com/a.png)\nhttps://x.com/post" in
  let json = B.blocks_to_yojson original in
  match B.blocks_of_yojson json with
  | Some parsed ->
    Alcotest.(check int) "roundtrip length" (List.length original) (List.length parsed);
    Alcotest.(check (list yojson_testable))
      "roundtrip json"
      (blocks_to_json_list original)
      (blocks_to_json_list parsed)
  | None -> Alcotest.fail "blocks_of_yojson rejected valid blocks"

let test_blocks_of_yojson_rejects_malformed () =
  Alcotest.(check bool) "not a list" true (B.blocks_of_yojson (`String "x") = None);
  Alcotest.(check bool) "empty list" true (B.blocks_of_yojson (`List []) = None);
  Alcotest.(check bool) "unknown tag"
    true
    (B.blocks_of_yojson (`List [ `Assoc [ ("t", `String "unknown") ] ]) = None)

let () =
  Alcotest.run "keeper_chat_blocks"
    [
      ( "parse",
        [
          Alcotest.test_case "plain text becomes escaped text block" `Quick
            test_plain_text_becomes_escaped_text_block;
          Alcotest.test_case "markdown image and surrounding text" `Quick
            test_markdown_image_and_surrounding_text;
          Alcotest.test_case "bare image url on own line" `Quick
            test_bare_image_url_on_own_line;
          Alcotest.test_case "standalone non-image url becomes link" `Quick
            test_standalone_non_image_url_becomes_link;
          Alcotest.test_case "inline url stays in text" `Quick
            test_inline_url_stays_in_text;
          Alcotest.test_case "multiple images and text lines" `Quick
            test_multiple_images_and_text_lines;
          Alcotest.test_case "empty lines ignored" `Quick
            test_empty_lines_ignored;
          Alcotest.test_case "www stripped from hostname" `Quick
            test_link_without_www;
        ] );
      ( "serialization",
        [
          Alcotest.test_case "blocks roundtrip through yojson" `Quick
            test_blocks_of_yojson_roundtrip;
          Alcotest.test_case "blocks_of_yojson rejects malformed" `Quick
            test_blocks_of_yojson_rejects_malformed;
        ] );
    ]
