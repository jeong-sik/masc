(** test_keeper_noop_backoff — Verify noop cycle classification and proactive
    backoff does not conflate opaque terminal runtime errors with transient
    verifier failures. *)

open Alcotest
module M = Masc.Keeper_unified_metrics_support

let is_noop = M.is_noop_cycle

let test_is_noop_cycle_text_only_is_visible_work () =
  check bool "text + no tools = visible work" false
    (is_noop ~has_text:true ~tools_used:[])

let test_is_noop_cycle_passive_tool () =
  (* Turn with only passive status tools and no text: noop *)
  check bool "no text + passive tools = noop" true (is_noop ~has_text:false ~tools_used:["board_list"])

let test_is_noop_cycle_not_noop_with_text () =
  (* Turn with text: not noop even if tools are passive *)
  check bool "text + passive tools = not noop" false (is_noop ~has_text:true ~tools_used:["board_list"])

let test_is_noop_cycle_not_noop_with_substantive_tool () =
  (* Turn with substantive tool: not noop *)
  check bool "no text + substantive tool = not noop" false (is_noop ~has_text:false ~tools_used:["tool_execute"])

let test_is_noop_cycle_empty () =
  (* Empty turn: noop *)
  check bool "no text + no tools = noop" true (is_noop ~has_text:false ~tools_used:[])

let () =
  run "keeper_noop_backoff"
    [ ( "is_noop_cycle"
      , [ test_case "text only is visible work" `Quick
            test_is_noop_cycle_text_only_is_visible_work
        ; test_case "passive tool, no text" `Quick test_is_noop_cycle_passive_tool
        ; test_case "text + passive tools" `Quick test_is_noop_cycle_not_noop_with_text
        ; test_case "substantive tool, no text" `Quick
            test_is_noop_cycle_not_noop_with_substantive_tool
        ; test_case "empty turn" `Quick test_is_noop_cycle_empty
        ] )
    ]
