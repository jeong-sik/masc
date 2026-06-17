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
    ]
