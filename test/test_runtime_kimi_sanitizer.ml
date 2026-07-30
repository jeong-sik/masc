open Alcotest

let test_sanitize_kimi_wire_corruption () =
  let corrupted = {|{"id":"chatcmpl-123","model":"kimi-for-coding","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"e"}}]},"finish_reasonhoices":[{"index":0,"delta":{}}]}]}|} in
  let expected = {|{"id":"chatcmpl-123","model":"kimi-for-coding","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"e"}}]},"finish_reason": null}, "choices":[{"index":0,"delta":{}}]}]}|} in
  let actual = Runtime_kimi_sanitizer.sanitize_wire_chunk corrupted in
  check string "corrupted finish_reasonhoices is auto-healed" expected actual

let () =
  run "Runtime_kimi_sanitizer"
    [ ("sanitizer", [ test_case "heal Kimi wire corruption" `Quick test_sanitize_kimi_wire_corruption ]) ]
