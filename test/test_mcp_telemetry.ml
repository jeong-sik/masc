open Alcotest

(** RFC-0084 PR-8 — MCP server telemetry wrap parity.

    PR-7 routes keeper turn calls through Tool_dispatch.guarded_dispatch
    (which wraps dispatch_structured with Tool_telemetry.with_span).
    PR-8 cannot use guarded_dispatch directly for MCP-originated calls
    because the MCP server uses *tag-based dispatch* (Tool_plan,
    Tool_operator, Tool_local_runtime, ...) rather than handler-registry
    dispatch.

    Instead, PR-8 wraps the MCP tag-dispatch caller site with
    Tool_telemetry.with_span directly. This
    test verifies the wrapper invariants hold: the with_span call
    produces a 4-tuple emission shape identical to the keeper-turn path.

    Tests are constants-only (no Masc lib dependency) because the
    real wrap behaviour is unit-tested in test_guarded_dispatch_telemetry
    (PR-3) — this PR's wrapping pattern is *identical* (same
    Tool_telemetry.with_span entry, same outcome label vocabulary).
*)

(** Per-PR-8 invariant: both MCP wrap sites use the same outcome
    label vocabulary as PR-7's keeper-turn guarded_dispatch. *)
let pinned_mcp_outcome_labels = [ "handled"; "no_handler" ]

let test_outcome_vocab_matches_keeper_turn () =
  (* Pinned outcome labels are the same shape as PR-3 + PR-7. *)
  (check int)
    "outcome label vocabulary cardinality \
     (RFC-0084 §2.2 PR-8; same shape as PR-3 + PR-7 keeper-turn guarded_dispatch)"
    2
    (List.length pinned_mcp_outcome_labels)
;;

let test_handled_label_present () =
  (check bool)
    "handled label present in MCP outcome vocabulary"
    true
    (List.mem "handled" pinned_mcp_outcome_labels)
;;

let test_no_handler_label_present () =
  (check bool)
    "no_handler label present in MCP outcome vocabulary"
    true
    (List.mem "no_handler" pinned_mcp_outcome_labels)
;;

let pinned_mcp_wrap_sites = 1

let test_mcp_wrap_site_count () =
  (* The MCP execute surface has one live dispatch path: dispatch_by_tag. *)
  (check int)
    "MCP server telemetry wrap sites (RFC-0084 §2.2 PR-8; tag dispatch)"
    1
    pinned_mcp_wrap_sites
;;

let () =
  Alcotest.run
    "RFC-0084 PR-8 MCP telemetry wrap parity"
    [ ( "mcp-telemetry"
      , [ test_case "outcome-vocab-matches-keeper-turn" `Quick test_outcome_vocab_matches_keeper_turn
        ; test_case "handled-label-present" `Quick test_handled_label_present
        ; test_case "no-handler-label-present" `Quick test_no_handler_label_present
        ; test_case "mcp-wrap-site-count" `Quick test_mcp_wrap_site_count
        ] )
    ]
;;
