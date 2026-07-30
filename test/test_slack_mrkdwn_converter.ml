open Alcotest

let test_markdown_to_slack_mrkdwn () =
  let input = "# Heading\n\nThis is **bold text** and a [Link & Details](https://example.com/foo).\n- Item 1\n- Item 2" in
  let expected = "*Heading*\n\nThis is *bold text* and a <https://example.com/foo|Link &amp; Details>.\n• Item 1\n• Item 2" in
  let actual = Slack_mrkdwn_converter.to_slack_mrkdwn input in
  check string "mrkdwn conversion with escaping matches" expected actual

let test_code_block_preservation () =
  let input = "Here is code:\n```\nlet x = **not_bold** in\n# Not header\n```\nAnd inline `**code**` here." in
  let expected = "Here is code:\n```\nlet x = **not_bold** in\n# Not header\n```\nAnd inline `**code**` here." in
  let actual = Slack_mrkdwn_converter.to_slack_mrkdwn input in
  check string "code blocks preserved untouched" expected actual

let () =
  run "Slack_mrkdwn_converter"
    [ ( "conformance"
      , [ test_case "convert markdown" `Quick test_markdown_to_slack_mrkdwn
        ; test_case "preserve code blocks" `Quick test_code_block_preservation
        ] )
    ]
