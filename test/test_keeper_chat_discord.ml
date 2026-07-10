open Alcotest

module D = Masc.Keeper_chat_discord.For_testing

let contains haystack needle =
  String_util.contains_substring haystack needle

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
