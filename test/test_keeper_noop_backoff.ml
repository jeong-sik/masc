(** test_keeper_noop_backoff — Verify noop cycle classification and
    that No_tool_capable (inside Runtime_exhausted) does NOT count
    toward proactive backoff.

    The exclusion was introduced because No_tool_capable is a
    configuration/capability mismatch (not transient), and counting it
    caused 59 spurious keeper fiber kills per day (#18315, #18317). *)

open Alcotest
module M = Masc.Keeper_unified_metrics_support

let is_noop = M.is_noop_cycle

let test_is_noop_cycle_text_only () =
  (* Text-only turn with no tools: noop *)
  check bool "text + no tools = noop" true (is_noop ~has_text:true ~observed_tool_names:[])

let test_is_noop_cycle_passive_tool () =
  (* Turn with only passive status tools and no text: noop *)
  check bool "no text + passive tools = noop" true (is_noop ~has_text:false ~observed_tool_names:["board_list"])

let test_is_noop_cycle_not_noop_with_text () =
  (* Turn with text: not noop even if tools are passive *)
  check bool "text + passive tools = not noop" false (is_noop ~has_text:true ~observed_tool_names:["board_list"])

let test_is_noop_cycle_not_noop_with_substantive_tool () =
  (* Turn with substantive tool: not noop *)
  check bool "no text + substantive tool = not noop" false (is_noop ~has_text:false ~observed_tool_names:["tool_execute"])

let test_is_noop_cycle_empty () =
  (* Empty turn: noop *)
  check bool "no text + no tools = noop" true (is_noop ~has_text:false ~observed_tool_names:[])

let () =
  run "keeper_noop_backoff"
    [ ( "is_noop_cycle"
      , [ test_case "text only" `Quick test_is_noop_cycle_text_only
        ; test_case "passive tool, no text" `Quick test_is_noop_cycle_passive_tool
        ; test_case "text + passive tools" `Quick test_is_noop_cycle_not_noop_with_text
        ; test_case "substantive tool, no text" `Quick
            test_is_noop_cycle_not_noop_with_substantive_tool
        ; test_case "empty turn" `Quick test_is_noop_cycle_empty
        ] )
    ]
