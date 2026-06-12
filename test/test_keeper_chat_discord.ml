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
    ]
