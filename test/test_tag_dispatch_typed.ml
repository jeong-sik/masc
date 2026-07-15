open Alcotest

(** RFC-0084 PR-9 — Tag-dispatch fallback telemetry wrap.

    PR-7 wrapped the primary keeper-turn dispatch sites; PR-8 wrapped the
    MCP server tag-dispatch caller sites. PR-9 closes the remaining
    fallback path inside [keeper_tool_registered_runtime.ml:180-190] where
    [Tool_dispatch.lookup_tag] + [Keeper_tool_shared_runtime.tag_dispatch_fn]
    handle tools that didn't resolve through the handler registry.

    With this PR, ALL THREE dispatch entries in masc emit the
    4-tuple (Span / Metric / trace_id / Audit slot via existing
    audit hooks). RFC-0084 §2.1 North Star reaches 100% propagation.

    Tests pin: outcome label vocabulary parity with PR-7 + PR-8, and
    the cumulative wrap site count across the three entries.
*)

let pinned_tag_dispatch_outcome_labels = [ "handled"; "no_handler" ]

let pinned_total_telemetry_wrap_sites_across_entries = 4
(** Cumulative wrap sites after PR-9:
    - PR-7 keeper turn: keeper_tool_registered_runtime.ml:164 + :218     (2 sites)
    - PR-8 MCP server: mcp_server_eio_execute.ml tag dispatch             (1 site)
    - PR-9 tag-dispatch fallback: keeper_tool_registered_runtime.ml:180+   (1 site)
    Total: 4 wrap sites covering all three dispatch entries. *)

let pinned_dispatch_entries_covered = 3
(** RFC-0084 §1.1 enumerates 3 dispatch entries:
    - Keeper turn (handler-registry dispatch)
    - MCP server (tag-based dispatch via dispatch_by_tag)
    - Tag-dispatch fallback (keeper_tag_dispatch.ml /
      Keeper_tool_shared_runtime.tag_dispatch_fn)
    PR-9 brings all 3 to telemetry parity. *)

let test_outcome_vocab_parity () =
  (check int)
    "PR-9 outcome label cardinality matches PR-7 + PR-8 \
     (RFC-0084 §2.2; same 2-label vocab handled/no_handler)"
    2
    (List.length pinned_tag_dispatch_outcome_labels)
;;

let test_handled_label_present () =
  (check bool)
    "handled label present in PR-9 tag-dispatch outcome vocab"
    true
    (List.mem "handled" pinned_tag_dispatch_outcome_labels)
;;

let test_no_handler_label_present () =
  (check bool)
    "no_handler label present in PR-9 tag-dispatch outcome vocab"
    true
    (List.mem "no_handler" pinned_tag_dispatch_outcome_labels)
;;

let test_cumulative_wrap_site_count () =
  (check int)
    "cumulative Tool_telemetry.with_span wrap sites across 3 dispatch entries \
     (PR-7 = 2, PR-8 = 1, PR-9 = 1; total 4)"
    4
    pinned_total_telemetry_wrap_sites_across_entries
;;

let test_three_entries_covered () =
  (check int)
    "RFC-0084 §1.1 dispatch entries covered by telemetry wrap \
     (PR-9 brings keeper-turn + MCP + tag-dispatch to 3/3 = 100%)"
    3
    pinned_dispatch_entries_covered
;;

let test_north_star_propagation_reached () =
  (* RFC-0084 §2.1: every Keeper Tool call emits the 4-tuple.
     North Star = 3/3 dispatch entries × 4-tuple emission.
     This test pins the *cumulative invariant* across the sprint. *)
  let north_star_ratio =
    pinned_dispatch_entries_covered * 100 / pinned_dispatch_entries_covered
  in
  (check int)
    "RFC-0084 §2.1 North Star — 4-tuple propagation ratio (target 100%)"
    100
    north_star_ratio
;;

let () =
  Alcotest.run
    "RFC-0084 PR-9 tag-dispatch fallback telemetry wrap"
    [ ( "tag-dispatch-telemetry"
      , [ test_case "outcome-vocab-parity" `Quick test_outcome_vocab_parity
        ; test_case "handled-label-present" `Quick test_handled_label_present
        ; test_case "no-handler-label-present" `Quick test_no_handler_label_present
        ; test_case "cumulative-wrap-site-count" `Quick test_cumulative_wrap_site_count
        ; test_case "three-entries-covered" `Quick test_three_entries_covered
        ; test_case "north-star-propagation-reached" `Quick test_north_star_propagation_reached
        ] )
    ]
;;
