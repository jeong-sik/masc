open Alcotest

let test_markdown_to_slack_mrkdwn () =
  let input = "# Heading\n\nThis is **bold text** and a [Link](https://example.com).\n- Item 1\n- Item 2" in
  let expected = "*Heading*\n\nThis is *bold text* and a <https://example.com|Link>.\n• Item 1\n• Item 2" in
  let actual = Slack_mrkdwn_converter.to_slack_mrkdwn input in
  check string "mrkdwn conversion matches" expected actual

let () =
  run "Slack_mrkdwn_converter"
    [ ("conformance", [ test_case "convert markdown" `Quick test_markdown_to_slack_mrkdwn ]) ]
