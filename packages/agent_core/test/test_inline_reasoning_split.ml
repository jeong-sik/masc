(* The defect this covers: a model that embeds reasoning in the content
   channel had it drawn as speech, because nothing separated the two. *)

open Llm_provider

module Split = Inline_reasoning_split

let check = Alcotest.(check string)

let feed_all pieces =
  let state = Split.create () in
  let reasoning = Buffer.create 64
  and text = Buffer.create 64 in
  List.iter
    (fun chunk ->
       let { Split.reasoning = r; text = t } = Split.feed state chunk in
       Buffer.add_string reasoning r;
       Buffer.add_string text t)
    pieces;
  let { Split.reasoning = r; text = t } = Split.flush state in
  Buffer.add_string reasoning r;
  Buffer.add_string text t;
  Buffer.contents reasoning, Buffer.contents text
;;

let test_whole_block () =
  let reasoning, text = feed_all [ "<think>weighing it</think>the answer" ] in
  check "reasoning is separated" "weighing it" reasoning;
  check "the answer survives" "the answer" text
;;

let test_untagged_text_is_untouched () =
  let reasoning, text = feed_all [ "plain reply, no tags at all" ] in
  check "no reasoning is invented" "" reasoning;
  check "every byte of the reply is kept" "plain reply, no tags at all" text
;;

let test_tag_split_across_deltas () =
  (* The tag arrives one byte at a time. A fragment of "<think>" must never
     reach the reply. *)
  let chunks = [ "<"; "th"; "in"; "k"; ">"; "mid-thought"; "</th"; "ink>"; "done" ] in
  let reasoning, text = feed_all chunks in
  check "reasoning is recovered across deltas" "mid-thought" reasoning;
  check "no tag fragment leaks into the reply" "done" text
;;

let test_lone_angle_bracket_is_reply_text () =
  let reasoning, text = feed_all [ "a < b and c > d" ] in
  check "no reasoning is invented" "" reasoning;
  check "comparison operators are not tags" "a < b and c > d" text
;;

let test_unterminated_tag_keeps_its_content () =
  (* Every unbalanced block measured on the live fleet was short exactly one
     closing tag: the stream was cut, not the reasoning absent. *)
  let reasoning, text = feed_all [ "<think>cut off here" ] in
  check "the cut thought is kept as reasoning" "cut off here" reasoning;
  check "and is not reported as speech" "" text
;;

let test_text_before_and_between_tags () =
  let reasoning, text =
    feed_all [ "before <think>one</think>middle<think>two</think>after" ]
  in
  check "both stretches of reasoning" "onetwo" reasoning;
  check "all three stretches of reply" "before middleafter" text
;;

let test_inside_reports_the_open_tag () =
  let state = Split.create () in
  let (_ : Split.piece) = Split.feed state "<think>still going" in
  Alcotest.(check bool) "inside an open tag" true (Split.inside state);
  let (_ : Split.piece) = Split.feed state "</think>" in
  Alcotest.(check bool) "closed again" false (Split.inside state)
;;

let () =
  Alcotest.run
    "inline_reasoning_split"
    [ ( "split"
      , [ Alcotest.test_case "whole block" `Quick test_whole_block
        ; Alcotest.test_case "untagged text is untouched" `Quick
            test_untagged_text_is_untouched
        ; Alcotest.test_case "tag split across deltas" `Quick
            test_tag_split_across_deltas
        ; Alcotest.test_case "lone angle bracket is reply text" `Quick
            test_lone_angle_bracket_is_reply_text
        ; Alcotest.test_case "unterminated tag keeps its content" `Quick
            test_unterminated_tag_keeps_its_content
        ; Alcotest.test_case "text before and between tags" `Quick
            test_text_before_and_between_tags
        ; Alcotest.test_case "inside reports the open tag" `Quick
            test_inside_reports_the_open_tag
        ] )
    ]
;;
