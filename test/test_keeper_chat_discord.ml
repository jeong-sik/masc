open Alcotest

module D = Masc.Keeper_chat_discord.For_testing

let contains haystack needle =
  String_util.contains_substring haystack needle

let run_adapter events ~post_message ~edit_message ~send_message =
  Eio_main.run
  @@ fun _env ->
  let stream = Masc.Keeper_chat_events.create () in
  List.iter (Masc.Keeper_chat_events.publish stream) events;
  let outcomes = ref [] in
  D.adapter_loop ~token:"test-token" ~channel_id:"test-channel"
    ~events:stream ~post_message ~edit_message ~send_message
    ~on_send_result:(fun result -> outcomes := result :: !outcomes) ();
  List.rev !outcomes

let check_single_ok label = function
  | [ Ok () ] -> ()
  | outcomes ->
      failf "%s: expected one Ok callback, got %d callback(s)" label
        (List.length outcomes)

let check_single_network_error label expected = function
  | [ Error (Discord_rest_client.Network actual) ] ->
      check string label expected actual
  | outcomes ->
      failf "%s: expected one Network error callback, got %d callback(s)"
        label (List.length outcomes)

let test_streaming_holds_back_trailing_token () =
  let content =
    D.streaming_patch_content "prefix sk-proj-abcdefghijklmnop"
  in
  check string "only stable prefix is published" "prefix " content;
  check bool "raw token prefix withheld" false (contains content "sk-proj")

let test_streaming_redacts_delimited_secret () =
  let secret = "sk-proj-abcdefghijklmnopqrstuvwxyz" in
  let content =
    D.streaming_patch_content ("prefix " ^ secret ^ " done ")
  in
  check bool "redaction marker present" true
    (contains content "[REDACTED]");
  check bool "raw secret removed" false (contains content secret)

let test_streaming_single_word_waits_for_final_send () =
  let content = D.streaming_patch_content "hello" in
  check string "no stable segment yet" "" content

let test_final_split_preserves_overflow () =
  let input = String.concat "" (List.init 420 (fun _ -> "word ")) in
  let head, overflow = D.final_head_and_overflow input in
  check int "head capped at Discord limit" 2000 (String.length head);
  match overflow with
  | None -> fail "expected overflow"
  | Some overflow ->
      check int "overflow preserves tail"
        (String.length input - 2000)
        (String.length overflow);
      check string "reconstructed final text" input (head ^ overflow)

let test_final_split_redacts_before_chunking () =
  let secret = "sk-proj-abcdefghijklmnopqrstuvwxyz" in
  let head, overflow =
    D.final_head_and_overflow ("prefix " ^ secret ^ " suffix")
  in
  let full =
    match overflow with
    | None -> head
    | Some overflow -> head ^ overflow
  in
  check bool "redaction marker present" true
    (contains full "[REDACTED]");
  check bool "raw secret removed" false (contains full secret)

let test_public_voice_audio_url_uses_base_url () =
  let url =
    D.public_voice_audio_url ~base_url:"https://chat.example.com" "tok123"
  in
  check string "audio URL"
    "https://chat.example.com/api/v1/voice/audio/tok123" url

let test_public_voice_audio_url_strips_trailing_slash () =
  let url =
    D.public_voice_audio_url ~base_url:"https://chat.example.com/" "tok123"
  in
  check string "audio URL"
    "https://chat.example.com/api/v1/voice/audio/tok123" url

let test_rich_embeds_of_text_projects_links_and_images () =
  let embeds =
    D.rich_embeds_of_text
      "https://example.com/page\n![diagram](https://example.com/diagram.png)\nplain text"
  in
  check int "two embeds" 2 (List.length embeds);
  let link_json =
    Discord_rest_client.embed_to_json (List.hd embeds) |> Yojson.Safe.to_string
  in
  check bool "link title" true (contains link_json "\"title\":\"example.com\"");
  check bool "link url" true
    (contains link_json "\"url\":\"https://example.com/page\"");
  let image_json =
    Discord_rest_client.embed_to_json (List.nth embeds 1)
    |> Yojson.Safe.to_string
  in
  check bool "image url" true
    (contains image_json "\"url\":\"https://example.com/diagram.png\"");
  check bool "image caption" true
    (contains image_json "\"description\":\"diagram\"")

let test_rich_embeds_redacts_text_derived_image_secrets () =
  let secret = "sk-proj-abcdefghijklmnopqrstuvwxyz" in
  let embeds =
    D.rich_embeds_of_text
      (Printf.sprintf "![%s](https://example.com/diagram.png?token=%s)"
         secret secret)
  in
  check int "one image embed" 1 (List.length embeds);
  let image_json =
    Discord_rest_client.embed_to_json (List.hd embeds) |> Yojson.Safe.to_string
  in
  check bool "raw secret removed" false (contains image_json secret);
  check bool "redaction marker present" true
    (contains image_json "[REDACTED]")

let test_rich_embeds_suppresses_credential_url () =
  let embeds =
    D.rich_embeds_of_text "https://user:pass@example.com/diagram.png"
  in
  check int "credential URL does not become embed" 0 (List.length embeds)

let test_rich_embeds_includes_code_and_mermaid () =
  let embeds =
    D.rich_embeds_of_text
      "```ocaml\nlet x = 1 + 2\n```\n```mermaid\nflowchart TD\nA-->B\n```"
  in
  check int "code and mermaid embeds" 2 (List.length embeds);
  let code_json = List.hd embeds |> Discord_rest_client.embed_to_json |> Yojson.Safe.to_string in
  check bool "code title" true (contains code_json "Code (ocaml)");
  check bool "code body" true
    (contains code_json "```ocaml\\nlet x = 1 + 2\\n```");
  let mermaid_json =
    List.nth embeds 1 |> Discord_rest_client.embed_to_json |> Yojson.Safe.to_string
  in
  check bool "mermaid title" true (contains mermaid_json "Mermaid Diagram");
  check bool "mermaid body" true
    (contains mermaid_json "```mermaid\\nflowchart TD\\nA-->B\\n```")

let test_terminal_callback_once_for_fallback_post () =
  let final_posts = ref [] in
  let outcomes =
    run_adapter
      [ Masc.Keeper_chat_events.Run_started
          { run_id = "run-fallback"; thread_id = "thread-fallback" }
      ; Masc.Keeper_chat_events.Text_delta "hello"
      ; Masc.Keeper_chat_events.Text_message_end
      ; Masc.Keeper_chat_events.Run_finished { run_id = "run-fallback" }
      ]
      ~post_message:(fun ~content:_ -> fail "stable prefix should not POST")
      ~edit_message:(fun ~message_id:_ ~content:_ ->
        fail "fallback delivery should not PATCH")
      ~send_message:(fun ~content ->
        final_posts := content :: !final_posts;
        Ok ())
  in
  check_single_ok "fallback terminal result" outcomes;
  check (list string) "one final POST" [ "hello" ] (List.rev !final_posts)

let test_terminal_callback_reports_final_patch_failure () =
  let patch_calls = ref 0 in
  let outcomes =
    run_adapter
      [ Masc.Keeper_chat_events.Run_started
          { run_id = "run-patch"; thread_id = "thread-patch" }
      ; Masc.Keeper_chat_events.Text_delta "hello "
      ; Masc.Keeper_chat_events.Text_message_end
      ; Masc.Keeper_chat_events.Run_finished { run_id = "run-patch" }
      ]
      ~post_message:(fun ~content ->
        check string "streaming POST content" "hello " content;
        Ok "discord-message-1")
      ~edit_message:(fun ~message_id ~content ->
        incr patch_calls;
        check string "final PATCH message" "discord-message-1" message_id;
        check string "final PATCH content" "hello " content;
        Error (Discord_rest_client.Network "final patch failed"))
      ~send_message:(fun ~content:_ -> fail "no overflow expected")
  in
  check int "one final PATCH" 1 !patch_calls;
  check_single_network_error "final PATCH failure" "final patch failed" outcomes

let test_terminal_callback_reports_overflow_failure () =
  let content = String.make 2100 'x' ^ " " in
  let overflow_posts = ref 0 in
  let outcomes =
    run_adapter
      [ Masc.Keeper_chat_events.Run_started
          { run_id = "run-overflow"; thread_id = "thread-overflow" }
      ; Masc.Keeper_chat_events.Text_delta content
      ; Masc.Keeper_chat_events.Text_message_end
      ; Masc.Keeper_chat_events.Run_finished { run_id = "run-overflow" }
      ]
      ~post_message:(fun ~content ->
        check int "streaming head length" 2000 (String.length content);
        Ok "discord-message-2")
      ~edit_message:(fun ~message_id:_ ~content ->
        check int "final head length" 2000 (String.length content);
        Ok ())
      ~send_message:(fun ~content ->
        incr overflow_posts;
        check int "overflow length" 101 (String.length content);
        Error (Discord_rest_client.Network "overflow failed"))
  in
  check int "one overflow POST" 1 !overflow_posts;
  check_single_network_error "overflow failure" "overflow failed" outcomes

let test_error_reply_callback_once () =
  let sends = ref 0 in
  let outcomes =
    run_adapter
      [ Masc.Keeper_chat_events.Run_started
          { run_id = "run-error"; thread_id = "thread-error" }
      ; Masc.Keeper_chat_events.Event_error { message = "provider failed" }
      ]
      ~post_message:(fun ~content:_ -> fail "error reply should use final sender")
      ~edit_message:(fun ~message_id:_ ~content:_ ->
        fail "error reply should not PATCH")
      ~send_message:(fun ~content ->
        incr sends;
        check string "error reply" "Keeper error: provider failed" content;
        Error (Discord_rest_client.Network "error post failed"))
  in
  check int "one error POST" 1 !sends;
  check_single_network_error "error POST failure" "error post failed" outcomes

let () =
  run "keeper_chat_discord"
    [ ( "streaming-redaction"
      , [ test_case "holds back trailing token" `Quick
            test_streaming_holds_back_trailing_token
        ; test_case "redacts delimited secret" `Quick
            test_streaming_redacts_delimited_secret
        ; test_case "single word waits for final send" `Quick
            test_streaming_single_word_waits_for_final_send
        ] )
    ; ( "final-delivery"
      , [ test_case "preserves overflow" `Quick
            test_final_split_preserves_overflow
        ; test_case "redacts before chunking" `Quick
            test_final_split_redacts_before_chunking
        ; test_case "callback once for fallback POST" `Quick
            test_terminal_callback_once_for_fallback_post
        ; test_case "callback reports final PATCH failure" `Quick
            test_terminal_callback_reports_final_patch_failure
        ; test_case "callback reports overflow failure" `Quick
            test_terminal_callback_reports_overflow_failure
        ; test_case "error reply callback exactly once" `Quick
            test_error_reply_callback_once
        ] )
    ; ( "rich-blocks"
      , [ test_case "audio URL uses base URL" `Quick
            test_public_voice_audio_url_uses_base_url
        ; test_case "audio URL strips trailing slash" `Quick
            test_public_voice_audio_url_strips_trailing_slash
        ; test_case "projects text links and images to embeds" `Quick
            test_rich_embeds_of_text_projects_links_and_images
        ; test_case "supports code and mermaid as embeds" `Quick
            test_rich_embeds_includes_code_and_mermaid
        ; test_case "redacts text-derived image secrets" `Quick
            test_rich_embeds_redacts_text_derived_image_secrets
        ; test_case "suppresses credential URL embeds" `Quick
            test_rich_embeds_suppresses_credential_url
        ] )
    ]
