open Alcotest

module S = Masc.Keeper_chat_slack.For_testing

let json_string json = Yojson.Safe.to_string json

let contains haystack needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let rec scan i =
    if i + nlen > hlen then false
    else if String.sub haystack i nlen = needle then true
    else scan (i + 1)
  in
  scan 0

let test_public_voice_audio_url_uses_base_url () =
  let url = S.public_voice_audio_url ~base_url:"https://chat.example.com" "tok123" in
  check string "audio URL"
    "https://chat.example.com/api/v1/voice/audio/tok123" url

let test_public_voice_audio_url_strips_trailing_slash () =
  let url =
    S.public_voice_audio_url ~base_url:"https://chat.example.com/" "tok123"
  in
  check string "audio URL"
    "https://chat.example.com/api/v1/voice/audio/tok123" url

let test_link_block_renders_section () =
  let json =
    S.link_block_json ~url:"https://example.com"
      ~title:"Example" ~description:(Some "A description")
  in
  let s = json_string json in
  check bool "type section" true (contains s "\"type\":\"section\"");
  check bool "mrkdwn text" true (contains s "\"type\":\"mrkdwn\"");
  check bool "link syntax" true (contains s "*<https://example.com|Example>*");
  check bool "description" true (contains s "A description")

let test_image_block_renders_image () =
  let json =
    S.image_block_json ~url:"https://example.com/img.png"
      ~caption:(Some "caption text")
  in
  let s = json_string json in
  check bool "type image" true (contains s "\"type\":\"image\"");
  check bool "image_url" true (contains s "\"image_url\":\"https://example.com/img.png\"");
  check bool "alt_text" true (contains s "\"alt_text\":\"caption text\"")

let test_audio_block_renders_voice_link () =
  let json =
    S.audio_block_json ~base_url:(Some "https://chat.example.com") ~token:"tok456"
      ~message_text:"hello"
  in
  let s = json_string json in
  check bool "type section" true (contains s "\"type\":\"section\"");
  check bool "voice link" true
    (contains s "<https://chat.example.com/api/v1/voice/audio/tok456|Voice message>");
  check bool "message text" true (contains s "hello")

let test_tool_context_block_renders_tool () =
  let json =
    S.tool_context_block_json ~name:"read_file" ~args_summary:"path: foo.txt"
      ~result_summary:(Some "contents")
  in
  let s = json_string json in
  check bool "type section" true (contains s "\"type\":\"section\"");
  check bool "tool name" true (contains s "*Tool: read_file*");
  check bool "args" true (contains s "args: path: foo.txt");
  check bool "result" true (contains s "result: contents")

(* ── content_blocks_of_text ─────────────────────────────────────── *)

let test_content_blocks_empty_for_plain_text () =
  let blocks = S.content_blocks_of_text "just plain text" in
  check int "no blocks" 0 (List.length blocks)

let test_content_blocks_detects_markdown_image () =
  let blocks =
    S.content_blocks_of_text "Hello ![alt text](https://example.com/img.png) world"
  in
  check int "one block" 1 (List.length blocks);
  let s = json_string (List.hd blocks) in
  check bool "type image" true (contains s "\"type\":\"image\"");
  check bool "image_url" true
    (contains s "\"image_url\":\"https://example.com/img.png\"");
  check bool "alt_text" true (contains s "\"alt_text\":\"alt text\"")

let test_content_blocks_detects_bare_image_url () =
  let blocks = S.content_blocks_of_text "https://example.com/photo.jpg" in
  check int "one block" 1 (List.length blocks);
  let s = json_string (List.hd blocks) in
  check bool "type image" true (contains s "\"type\":\"image\"");
  check bool "image_url" true
    (contains s "\"image_url\":\"https://example.com/photo.jpg\"")

let test_content_blocks_detects_link () =
  let blocks = S.content_blocks_of_text "https://example.com/page" in
  check int "one block" 1 (List.length blocks);
  let s = json_string (List.hd blocks) in
  check bool "type section" true (contains s "\"type\":\"section\"");
  check bool "link syntax" true (contains s "*<https://example.com/page|example.com>*")

let test_content_blocks_mixed_content () =
  let blocks =
    S.content_blocks_of_text
      "Check this out\nhttps://example.com/page\n![diagram](https://example.com/diagram.png)\nignore me"
  in
  check int "two blocks" 2 (List.length blocks)

let () =
  run "keeper_chat_slack"
    [
      ( "audio-url"
      , [ test_case "uses base URL" `Quick test_public_voice_audio_url_uses_base_url
        ; test_case "strips trailing slash" `Quick
            test_public_voice_audio_url_strips_trailing_slash
        ] )
    ; ( "block-rendering"
      , [ test_case "link block renders section" `Quick test_link_block_renders_section
        ; test_case "image block renders image" `Quick test_image_block_renders_image
        ; test_case "audio block renders voice link" `Quick
            test_audio_block_renders_voice_link
        ; test_case "tool context block renders tool" `Quick
            test_tool_context_block_renders_tool
        ] )
    ; ( "content-blocks"
      , [ test_case "empty for plain text" `Quick
            test_content_blocks_empty_for_plain_text
        ; test_case "detects markdown image" `Quick
            test_content_blocks_detects_markdown_image
        ; test_case "detects bare image URL" `Quick
            test_content_blocks_detects_bare_image_url
        ; test_case "detects link" `Quick test_content_blocks_detects_link
        ; test_case "mixed content" `Quick test_content_blocks_mixed_content
        ] )
    ]
