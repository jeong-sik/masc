open Alcotest
module Opc = Masc_mcp.Operator_pending_confirm

let na = Opc.normalized_actor

let test_explicit_raw () =
  check string "explicit raw" "alice" (na ~context_actor:"" (Some "alice"))
;;

let test_raw_trimmed () =
  check string "raw trimmed" "bob" (na ~context_actor:"" (Some "  bob  "))
;;

let test_empty_raw_uses_context () =
  check string "empty raw" "ctx-agent" (na ~context_actor:"ctx-agent" (Some ""))
;;

let test_none_uses_context () =
  check string "none" "ctx-agent" (na ~context_actor:"ctx-agent" None)
;;

let test_blank_context_returns_unknown () =
  check string "blank context" "unknown" (na ~context_actor:"" None)
;;

let test_unknown_context_returns_unknown () =
  check string "unknown context" "unknown" (na ~context_actor:"unknown" None)
;;

let test_whitespace_context_returns_unknown () =
  check string "whitespace context" "unknown" (na ~context_actor:"  " None)
;;

let tests =
  [ test_case "explicit raw" `Quick test_explicit_raw
  ; test_case "raw trimmed" `Quick test_raw_trimmed
  ; test_case "empty raw uses context" `Quick test_empty_raw_uses_context
  ; test_case "none uses context" `Quick test_none_uses_context
  ; test_case "blank context returns unknown" `Quick test_blank_context_returns_unknown
  ; test_case
      "unknown context returns unknown"
      `Quick
      test_unknown_context_returns_unknown
  ; test_case
      "whitespace context returns unknown"
      `Quick
      test_whitespace_context_returns_unknown
  ]
;;

let () = run "normalized_actor" [ "normalized_actor", tests ]
