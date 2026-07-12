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

let test_escape_mrkdwn_control_chars () =
  check string "control chars escaped"
    "&lt;@U123&gt; &amp; &lt;b&gt;"
    (S.escape_mrkdwn_text "<@U123> & <b>")

let test_link_block_escapes_mrkdwn_fields () =
  let json =
    S.link_block_json ~url:"https://example.com/?a=1&b=2"
      ~title:"<@U123> & title" ~description:(Some "a > b")
  in
  let s = json_string json in
  check bool "raw mention removed" false (contains s "<@U123>");
  check bool "title escaped" true (contains s "&lt;@U123&gt; &amp; title");
  check bool "url escaped" true
    (contains s "<https://example.com/?a=1&amp;b=2|");
  check bool "description escaped" true (contains s "a &gt; b")

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

let test_audio_block_escapes_message_text () =
  let json =
    S.audio_block_json ~base_url:(Some "https://chat.example.com") ~token:"tok456"
      ~message_text:"<@U123> & done"
  in
  let s = json_string json in
  check bool "raw mention removed" false (contains s "<@U123>");
  check bool "message escaped" true (contains s "&lt;@U123&gt; &amp; done")

let test_tool_context_block_renders_tool () =
  let json =
    S.tool_context_block_json ~name:"read_file" ~args_summary:"path: foo.txt"
      ~result_summary:(Some "contents")
  in
  let s = json_string json in
  check bool "type section" true (contains s "\"type\":\"section\"");
  check bool "tool name" true (contains s "*Tool:* read_file");
  check bool "args" true (contains s "args: path: foo.txt");
  check bool "result" true (contains s "result: contents")

let test_tool_context_block_escapes_summaries () =
  let json =
    S.tool_context_block_json ~name:"<tool>" ~args_summary:"<@U123> & args"
      ~result_summary:(Some "result > ok")
  in
  let s = json_string json in
  check bool "raw mention removed" false (contains s "<@U123>");
  check bool "name escaped" true (contains s "&lt;tool&gt;");
  check bool "args escaped" true (contains s "&lt;@U123&gt; &amp; args");
  check bool "result escaped" true (contains s "result &gt; ok")

let test_truncate_to_limit_keeps_utf8_boundary () =
  let s = String.concat "" (List.init 10 (fun _ -> "가")) in
  let truncated = S.truncate_to_limit s 4 in
  check bool "valid utf8" true (String.is_valid_utf_8 truncated);
  check string "first four codepoints" "가가가가" truncated

let test_limit_blocks_adds_visible_omission_notice () =
  let mk_block n =
    S.link_block_json ~url:(Printf.sprintf "https://example.com/%d" n)
      ~title:(Printf.sprintf "item %d" n) ~description:None
  in
  let blocks = List.init 55 mk_block |> S.limit_blocks_for_slack in
  check int "max 50 blocks" 50 (List.length blocks);
  let last = List.nth blocks 49 |> json_string in
  check bool "visible omission notice" true
    (contains last "6 Slack block(s) omitted")

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

let test_content_blocks_detects_code () =
  let blocks = S.content_blocks_of_text "```ocaml\nlet x = 1 + 2\n```" in
  check int "one code block" 1 (List.length blocks);
  let s = json_string (List.hd blocks) in
  check bool "code block text" true (contains s "```ocaml")

let test_content_blocks_detects_mermaid () =
  let blocks = S.content_blocks_of_text "```mermaid\nflowchart TD\nA-->B\n```" in
  check int "one mermaid block" 1 (List.length blocks);
  let s = json_string (List.hd blocks) in
  check bool "mermaid block text" true (contains s "```mermaid")

let test_content_blocks_mixed_content () =
  let blocks =
    S.content_blocks_of_text
      "Check this out\nhttps://example.com/page\n![diagram](https://example.com/diagram.png)\nignore me"
  in
  check int "two blocks" 2 (List.length blocks)

let test_content_blocks_redacts_text_derived_image_secrets () =
  let secret = "sk-proj-abcdefghijklmnopqrstuvwxyz" in
  let blocks =
    S.content_blocks_of_text
      (Printf.sprintf "![%s](https://example.com/diagram.png?token=%s)"
         secret secret)
  in
  check int "one image block" 1 (List.length blocks);
  let s = json_string (List.hd blocks) in
  check bool "raw secret removed" false (contains s secret);
  check bool "redaction marker present" true (contains s "[REDACTED]")

let test_content_blocks_suppresses_credential_url () =
  let blocks =
    S.content_blocks_of_text "https://user:pass@example.com/diagram.png"
  in
  check int "credential URL does not become block" 0 (List.length blocks)

let test_final_message_blocks_merges_text_and_event_blocks () =
  let event_block =
    S.link_block_json ~url:"https://event.example.com"
      ~title:"event" ~description:None
  in
  let blocks =
    S.final_message_blocks
      ~content:"https://example.com/photo.jpg"
      ~event_blocks:[ event_block ]
  in
  check int "text block plus event block" 2 (List.length blocks);
  let first = json_string (List.hd blocks) in
  check bool "text-derived image first" true
    (contains first "\"image_url\":\"https://example.com/photo.jpg\"");
  let second = json_string (List.nth blocks 1) in
  check bool "event block preserved" true
    (contains second "https://event.example.com")

let run_adapter events ~send_plain ~send_blocks =
  Eio_main.run @@ fun _env ->
  let stream = Masc.Keeper_chat_events.create () in
  List.iter (Masc.Keeper_chat_events.publish stream) events;
  let outcomes = ref [] in
  S.adapter_loop ~events:stream ~send_plain ~send_blocks
    ~on_send_result:(fun result -> outcomes := result :: !outcomes)
    ();
  List.rev !outcomes

let test_adapter_terminal_success_once () =
  let sends = ref [] in
  let outcomes =
    run_adapter
      [ Masc.Keeper_chat_events.Run_started
          { run_id = "run-1"; thread_id = "thread-1" }
      ; Masc.Keeper_chat_events.Text_delta "done"
      ; Masc.Keeper_chat_events.Run_finished { run_id = "run-1" }
      ]
      ~send_plain:(fun ~content ->
        sends := ("plain", content) :: !sends;
        Ok ())
      ~send_blocks:(fun ~content ~blocks:_ ->
        sends := ("blocks", content) :: !sends;
        Ok ())
  in
  check int "one terminal callback" 1 (List.length outcomes);
  check bool "terminal callback succeeds" true (outcomes = [ Ok () ]);
  check (list (pair string string)) "one final blocks send"
    [ "blocks", "done" ] (List.rev !sends)

let test_protocol_diagnostic_cannot_mask_final_failure () =
  let protocol_error : Masc.Keeper_chat_events.stream_protocol_error =
    { kind = Masc.Keeper_chat_events.Sse_error
    ; index = None
    ; tool_call_id = None
    ; event_type = Some "error"
    ; reason = Some "upstream warning"
    ; raw_bytes = None
    }
  in
  let outcomes =
    run_adapter
      [ Masc.Keeper_chat_events.Oas_stream_protocol_error protocol_error
      ; Masc.Keeper_chat_events.Text_delta "final"
      ; Masc.Keeper_chat_events.Run_finished { run_id = "run-2" }
      ]
      ~send_plain:(fun ~content:_ -> Ok ())
      ~send_blocks:(fun ~content:_ ~blocks:_ ->
        Error (Masc.Keeper_chat_slack.Other "final send failed"))
  in
  match outcomes with
  | [ Error (Masc.Keeper_chat_slack.Other message) ] ->
    check string "final error wins" "final send failed" message
  | _ -> fail "only the terminal final-send failure settles the callback"

let test_adapter_empty_terminal_is_error () =
  let sends = ref 0 in
  let outcomes =
    run_adapter
      [ Masc.Keeper_chat_events.Run_finished { run_id = "run-empty" } ]
      ~send_plain:(fun ~content:_ ->
        incr sends;
        Ok ())
      ~send_blocks:(fun ~content:_ ~blocks:_ ->
        incr sends;
        Ok ())
  in
  check int "empty terminal makes no Slack call" 0 !sends;
  match outcomes with
  | [ Error (Masc.Keeper_chat_slack.Other message) ] ->
    check bool "empty terminal failure is explicit" true
      (contains message "no text or blocks")
  | _ -> fail "empty terminal must settle exactly once with an error"

let test_adapter_typed_cancellation_sends_notice () =
  let sends = ref [] in
  let outcomes =
    run_adapter
      [ Masc.Keeper_chat_events.Run_cancelled
          { run_id = "run-cancel"; message = "operator stopped the turn" }
      ]
      ~send_plain:(fun ~content ->
        sends := content :: !sends;
        Ok ())
      ~send_blocks:(fun ~content:_ ~blocks:_ ->
        fail "typed cancellation must use the plain terminal sender")
  in
  check (list string) "one explicit cancellation notice"
    [ "Keeper request cancelled: operator stopped the turn" ]
    (List.rev !sends);
  check bool "cancellation notice delivery settles successfully" true
    (outcomes = [ Ok () ])

let test_message_body_preserves_reply_thread () =
  let body =
    Masc.Keeper_chat_slack.For_testing.build_message_body
      ~channel:"C-thread" ~content:"deferred reply" ~blocks:[]
      ~thread_ts:"1710000000.123456" ()
    |> Yojson.Safe.from_string
  in
  let open Yojson.Safe.Util in
  check string "channel retained" "C-thread" (body |> member "channel" |> to_string);
  check string "reply thread retained" "1710000000.123456"
    (body |> member "thread_ts" |> to_string)

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
        ; test_case "escapes mrkdwn control chars" `Quick
            test_escape_mrkdwn_control_chars
        ; test_case "link block escapes mrkdwn fields" `Quick
            test_link_block_escapes_mrkdwn_fields
        ; test_case "image block renders image" `Quick test_image_block_renders_image
        ; test_case "audio block renders voice link" `Quick
            test_audio_block_renders_voice_link
        ; test_case "audio block escapes message text" `Quick
            test_audio_block_escapes_message_text
        ; test_case "tool context block renders tool" `Quick
            test_tool_context_block_renders_tool
        ; test_case "tool context block escapes summaries" `Quick
            test_tool_context_block_escapes_summaries
        ; test_case "truncate keeps utf8 boundary" `Quick
            test_truncate_to_limit_keeps_utf8_boundary
        ; test_case "block limit adds visible omission notice" `Quick
            test_limit_blocks_adds_visible_omission_notice
        ] )
    ; ( "content-blocks"
      , [ test_case "empty for plain text" `Quick
            test_content_blocks_empty_for_plain_text
        ; test_case "detects markdown image" `Quick
            test_content_blocks_detects_markdown_image
        ; test_case "detects code fences" `Quick
            test_content_blocks_detects_code
        ; test_case "detects mermaid blocks" `Quick
            test_content_blocks_detects_mermaid
        ; test_case "detects bare image URL" `Quick
            test_content_blocks_detects_bare_image_url
        ; test_case "detects link" `Quick test_content_blocks_detects_link
        ; test_case "mixed content" `Quick test_content_blocks_mixed_content
        ; test_case "redacts text-derived image secrets" `Quick
            test_content_blocks_redacts_text_derived_image_secrets
        ; test_case "suppresses credential URL blocks" `Quick
            test_content_blocks_suppresses_credential_url
        ; test_case "final delivery merges text and event blocks" `Quick
            test_final_message_blocks_merges_text_and_event_blocks
        ] )
    ; ( "terminal-receipt"
      , [ test_case "terminal success settles once" `Quick
            test_adapter_terminal_success_once
        ; test_case "protocol diagnostic cannot mask final failure" `Quick
            test_protocol_diagnostic_cannot_mask_final_failure
        ; test_case "empty terminal is explicit failure" `Quick
            test_adapter_empty_terminal_is_error
        ; test_case "typed cancellation sends explicit notice" `Quick
            test_adapter_typed_cancellation_sends_notice
        ] )
    ; ( "thread-routing"
      , [ test_case "deferred reply keeps thread_ts" `Quick
            test_message_body_preserves_reply_thread
        ] )
    ]
