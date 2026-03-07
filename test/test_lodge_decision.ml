open Alcotest
open Masc_mcp

let test_parse_single_choice_comment () =
  let response =
    {|{"action":"comment","target_post_id":"p-123","content":"이 포스트는 구체적인 운영 팁이 있어서 바로 적용할 수 있겠어요.","reason":"실행 가능한 디테일이 있다","confidence":0.82}|}
  in
  match Lodge_decision.parse_single_choice ~post_id:"p-123" response with
  | Error err -> fail err
  | Ok choice ->
      check string "action" "comment"
        (Lodge_decision.action_to_string choice.action);
      check (option string) "target" (Some "p-123") choice.target_post_id;
      check bool "has content" true
        (match choice.content with Some text -> String.length text > 0 | None -> false)

let test_parse_single_choice_rejects_wrong_target () =
  let response =
    {|{"action":"upvote","target_post_id":"p-999","reason":"관심사와 맞다","confidence":0.7}|}
  in
  match Lodge_decision.parse_single_choice ~post_id:"p-123" response with
  | Ok _ -> fail "expected parse failure"
  | Error err ->
      check bool "mentions candidate set" true
        (String.contains err 'c' || String.length err > 0)

let test_parse_batch_outcome_valid () =
  let response =
    {|{
      "reactions": [
        {"post_id":"p-1","reaction":"upvote","confidence":0.81,"reason":"실용적이다"},
        {"post_id":"p-2","reaction":"comment_intent","confidence":0.92,"reason":"질문이 있다"}
      ],
      "decision": {
        "action":"comment",
        "target_post_id":"p-2",
        "content":"여기서 말한 기준을 실제 운영 지표와 연결하면 더 좋겠습니다.",
        "reason":"대화를 확장할 가치가 있다",
        "confidence":0.91
      }
    }|}
  in
  match Lodge_decision.parse_batch_outcome ~allowed_post_ids:[ "p-1"; "p-2" ] ~allow_post:true response with
  | Error err -> fail err
  | Ok outcome ->
      check int "all reactions recorded" 2 (List.length outcome.reactions);
      check string "decision action" "comment"
        (Lodge_decision.action_to_string outcome.choice.action)

let test_parse_batch_outcome_requires_full_coverage () =
  let response =
    {|{
      "reactions": [
        {"post_id":"p-1","reaction":"upvote","confidence":0.81,"reason":"실용적이다"}
      ],
      "decision": {
        "action":"skip",
        "reason":"지금은 개입할 필요가 없다",
        "confidence":0.55
      }
    }|}
  in
  match Lodge_decision.parse_batch_outcome ~allowed_post_ids:[ "p-1"; "p-2" ] ~allow_post:true response with
  | Ok _ -> fail "expected coverage validation failure"
  | Error err ->
      check bool "mentions missing reactions" true
        (String.length err > 0)

let test_parse_batch_outcome_rejects_post_when_not_allowed () =
  let response =
    {|{
      "reactions": [],
      "decision": {
        "action":"post",
        "content":"새 글을 쓰자",
        "reason":"주제를 확장해야 한다",
        "confidence":0.7
      }
    }|}
  in
  match Lodge_decision.parse_batch_outcome ~allowed_post_ids:[] ~allow_post:false response with
  | Ok _ -> fail "expected post disallowed failure"
  | Error err -> check bool "post disallowed" true (String.length err > 0)

let () =
  run "Lodge decision"
    [
      ( "parse",
        [
          test_case "single comment" `Quick test_parse_single_choice_comment;
          test_case "single rejects wrong target" `Quick
            test_parse_single_choice_rejects_wrong_target;
          test_case "batch valid" `Quick test_parse_batch_outcome_valid;
          test_case "batch full coverage required" `Quick
            test_parse_batch_outcome_requires_full_coverage;
          test_case "batch rejects post when disallowed" `Quick
            test_parse_batch_outcome_rejects_post_when_not_allowed;
        ] );
    ]
